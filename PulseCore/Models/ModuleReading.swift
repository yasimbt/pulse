/// What the menu bar shows for a module, independent of how it is drawn.
public struct ModuleReading: Sendable, Equatable {
    /// The compact value drawn in the menu bar.
    public let text: String
    /// 0...1 for bar and gauge renderers.
    public let fraction: Double
    /// The series a sparkline plots. Network plots download.
    public let series: SeriesID
    /// Full sentence for VoiceOver.
    public let accessibilityValue: String

    /// Floor for auto-scaling, so an idle link does not fill the bar with a few bytes.
    static let minimumRateScale = 1_000_000.0
    /// Floor for auto-scaling power, so an idle Mac does not fill the bar.
    static let minimumWattScale = 10.0

    public static func make(_ kind: ModuleKind, snapshot: Snapshot, recentPeak: Double) -> ModuleReading? {
        switch kind {
        case .cpu:
            return snapshot.cpu.map {
                let value = MetricFormat.percent($0.total)
                return ModuleReading(text: value, fraction: $0.total, series: .cpuTotal, accessibilityValue: "CPU \(value) used")
            }
        case .memory:
            return snapshot.memory.map {
                let value = MetricFormat.percent($0.usedFraction)
                return ModuleReading(text: value, fraction: $0.usedFraction, series: .memoryUsed, accessibilityValue: "Memory \(value) used")
            }
        case .disk:
            return snapshot.disk.map {
                let value = MetricFormat.percent($0.usedFraction)
                return ModuleReading(text: value, fraction: $0.usedFraction, series: .diskRead, accessibilityValue: "Disk \(value) full")
            }
        case .network:
            return snapshot.network.map {
                ModuleReading(
                    text: "↓\(MetricFormat.compactRate($0.downBytesPerSecond)) ↑\(MetricFormat.compactRate($0.upBytesPerSecond))",
                    fraction: min(1, $0.downBytesPerSecond / max(recentPeak, minimumRateScale)),
                    series: .networkDown,
                    accessibilityValue: "Network \(MetricFormat.rate($0.downBytesPerSecond)) down, \(MetricFormat.rate($0.upBytesPerSecond)) up"
                )
            }
        case .battery:
            return snapshot.battery.map {
                let value = MetricFormat.percent($0.chargeFraction)
                let state = $0.isCharging ? "charging" : ($0.isExternalPowerConnected ? "on power adapter" : "on battery")
                return ModuleReading(
                    text: value,
                    fraction: $0.chargeFraction,
                    series: .batteryCharge,
                    accessibilityValue: "Battery \(value), \(state)"
                )
            }
        case .power:
            return power(snapshot, recentPeak: recentPeak)
        case .ports:
            return ports(snapshot)
        }
    }

    private static func power(_ snapshot: Snapshot, recentPeak: Double) -> ModuleReading? {
        guard let power = snapshot.power, power.cpuWatts != nil else { return nil }
        let total = power.totalWatts
        return ModuleReading(
            text: MetricFormat.compactWatts(total),
            fraction: min(1, total / max(recentPeak, minimumWattScale)),
            series: .powerTotal,
            accessibilityValue: "Power \(MetricFormat.watts(total)), CPU and GPU"
        )
    }

    /// The charger's input while one is connected; otherwise how many ports are in use.
    private static func ports(_ snapshot: Snapshot) -> ModuleReading? {
        guard let ports = snapshot.ports else { return nil }
        if let charger = ports.charger {
            // Measured input once macOS has it; the charger's rating until then.
            let watts = charger.inputWatts ?? charger.advertisedWatts ?? 0
            return ModuleReading(
                text: "⚡" + MetricFormat.compactWatts(watts),
                fraction: min(1, (charger.inputWatts ?? 0) / max(charger.advertisedWatts ?? 0, 1)),
                series: .powerTotal,
                accessibilityValue: "Charger connected, \(MetricFormat.watts(watts))"
            )
        }
        let inUse = ports.ports.filter(\.isConnected).count
        return ModuleReading(
            text: "\(inUse)",
            fraction: Double(inUse) / Double(max(ports.ports.count, 1)),
            series: .powerTotal,
            accessibilityValue: "\(inUse) of \(ports.ports.count) ports in use"
        )
    }
}
