import Foundation

/// Threshold alerts, with how long a condition must last before it fires and how long to stay
/// quiet afterwards. Pure, so that timing is testable; the app turns events into notifications.
public enum AlertKind: String, CaseIterable, Codable, Sendable {
    case chipTemperature
    case swapGrowth
    case lowDiskSpace
    case batteryHealth
    case thermalPressure
    case chargerShortfall

    public var title: String {
        switch self {
        case .chipTemperature: "Chip temperature"
        case .swapGrowth: "Swap growth"
        case .lowDiskSpace: "Low disk space"
        case .batteryHealth: "Battery health"
        case .thermalPressure: "Sustained throttling"
        case .chargerShortfall: "Charger can't keep up"
        }
    }

    /// Quiet time after an alert, so that a lasting condition doesn't repeat it.
    var cooldown: TimeInterval {
        switch self {
        case .lowDiskSpace: 6 * 3600
        case .batteryHealth: 7 * 86400
        default: 30 * 60
        }
    }
}

/// Which alerts are on, and their thresholds. Saved with the settings.
public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Set<AlertKind>
    public var chipCelsius: Double
    public var swapGrowthBytes: Double
    public var minimumFreeBytes: Double
    public var minimumBatteryHealth: Double

    public static let `default` = AlertSettings(
        enabled: [],
        chipCelsius: 95,
        swapGrowthBytes: 2e9,
        minimumFreeBytes: 10e9,
        minimumBatteryHealth: 0.8
    )

    public init(enabled: Set<AlertKind>, chipCelsius: Double, swapGrowthBytes: Double, minimumFreeBytes: Double, minimumBatteryHealth: Double) {
        self.enabled = enabled
        self.chipCelsius = chipCelsius
        self.swapGrowthBytes = swapGrowthBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumBatteryHealth = minimumBatteryHealth
    }
}

public struct AlertEvent: Sendable, Equatable {
    public let kind: AlertKind
    public let title: String
    public let body: String
}

/// Tracks how long each condition has held and when each alert last fired.
public struct AlertEngine: Sendable {
    /// A condition's state in one snapshot. Some readings come only every few seconds, and a
    /// snapshot without them mustn't reset a condition that's been building up.
    enum Condition {
        case unknown
        case clear
        case active(String)
    }

    /// How long a condition must hold before it fires.
    static let sustain: [AlertKind: TimeInterval] = [
        .chipTemperature: 60, .chargerShortfall: 60, .lowDiskSpace: 0, .batteryHealth: 0, .swapGrowth: 0
    ]
    static let swapWindow: TimeInterval = 600
    static let fairPressureSustain: TimeInterval = 180
    static let seriousPressureSustain: TimeInterval = 30

    private var since: [AlertKind: Date] = [:]
    private var fairSince: Date?
    private var lastFired: [AlertKind: Date] = [:]
    private var swap: [(time: Date, bytes: Double)] = []

    public init() {}

    /// Checks a snapshot and returns the alerts that should be shown now.
    public mutating func evaluate(_ snapshot: Snapshot, settings: AlertSettings) -> [AlertEvent] {
        let now = snapshot.timestamp
        var events: [AlertEvent] = []
        func check(_ kind: AlertKind, _ condition: Condition) {
            guard settings.enabled.contains(kind) else {
                since[kind] = nil
                return
            }
            let message: String
            switch condition {
            case .unknown: return
            case .clear:
                since[kind] = nil
                return
            case let .active(text): message = text
            }
            let start = since[kind] ?? now
            since[kind] = start
            guard now.timeIntervalSince(start) >= (Self.sustain[kind] ?? 0) else { return }
            if let last = lastFired[kind], now.timeIntervalSince(last) < kind.cooldown { return }
            lastFired[kind] = now
            events.append(AlertEvent(kind: kind, title: kind.title, body: message))
        }
        check(.chipTemperature, chipTemperature(snapshot, settings))
        check(.swapGrowth, swapGrowth(snapshot, settings, now))
        check(.lowDiskSpace, lowDisk(snapshot, settings))
        check(.batteryHealth, batteryHealth(snapshot, settings))
        check(.thermalPressure, thermalPressure(snapshot, now))
        check(.chargerShortfall, chargerShortfall(snapshot))
        return events
    }

    private func chipTemperature(_ snapshot: Snapshot, _ settings: AlertSettings) -> Condition {
        guard let chip = snapshot.thermal?.reading("chipHottest")?.celsius else { return .unknown }
        guard chip >= settings.chipCelsius else { return .clear }
        return .active("The chip has been at \(MetricFormat.temperature(chip)) for a minute.")
    }

    private mutating func swapGrowth(_ snapshot: Snapshot, _ settings: AlertSettings, _ now: Date) -> Condition {
        guard let used = snapshot.memory.map({ Double($0.swapUsedBytes) }) else { return .unknown }
        swap.append((now, used))
        swap.removeAll { now.timeIntervalSince($0.time) > Self.swapWindow }
        guard let lowest = swap.map(\.bytes).min(), used - lowest >= settings.swapGrowthBytes else { return .clear }
        return .active("Swap grew by \(MetricFormat.memory(used - lowest)) in 10 minutes, to \(MetricFormat.memory(used)). Memory is short.")
    }

    private func lowDisk(_ snapshot: Snapshot, _ settings: AlertSettings) -> Condition {
        guard let disk = snapshot.disk, disk.totalBytes > 0 else { return .unknown }
        let free = Double(disk.availableBytes)
        guard free < settings.minimumFreeBytes || free / Double(disk.totalBytes) < 0.05 else { return .clear }
        return .active("Only \(MetricFormat.bytes(free)) is free on the startup disk.")
    }

    private func batteryHealth(_ snapshot: Snapshot, _ settings: AlertSettings) -> Condition {
        guard let battery = snapshot.battery else { return .unknown }
        guard let health = battery.healthFraction, health < settings.minimumBatteryHealth else { return .clear }
        return .active("The battery holds \(MetricFormat.percent(health)) of its original capacity.")
    }

    private func chargerShortfall(_ snapshot: Snapshot) -> Condition {
        guard let ports = snapshot.ports else { return .unknown }
        return ports.charger.flatMap(PortAlerts.chargerShortfall).map(Condition.active) ?? .clear
    }

    /// macOS's thermal pressure stands in for frequency-based throttle detection, which needs the
    /// costly per-second detail. On the M5 Air it reached "fair" about a minute into throttling.
    private mutating func thermalPressure(_ snapshot: Snapshot, _ now: Date) -> Condition {
        guard let state = snapshot.thermal?.state else { return .unknown }
        guard state >= .fair else {
            fairSince = nil
            return .clear
        }
        let start = fairSince ?? now
        fairSince = start
        let held = now.timeIntervalSince(start)
        let serious = state >= .serious && held >= Self.seriousPressureSustain
        guard serious || held >= Self.fairPressureSustain else { return .clear }
        return .active("The Mac has been under \(state == .fair ? "moderate" : "heavy") thermal pressure for \(MetricFormat.clock(held)). "
            + "It's likely running slower to stay cool.")
    }
}
