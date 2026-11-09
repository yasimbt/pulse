import Foundation
import IOKit.ps

/// What a rule changes while its condition holds.
public struct RuleActions: Codable, Equatable, Sendable {
    /// A slower sample rate, or nil to keep the usual one.
    public var sampleInterval: Double?
    /// Modules taken out of the menu bar.
    public var hiddenModules: Set<ModuleKind>

    public static let none = RuleActions(sampleInterval: nil, hiddenModules: [])

    public init(sampleInterval: Double?, hiddenModules: Set<ModuleKind>) {
        self.sampleInterval = sampleInterval
        self.hiddenModules = hiddenModules
    }

    public var isEmpty: Bool { sampleInterval == nil && hiddenModules.isEmpty }
}

/// Built-in rules, such as "on battery, sample every 5 s and hide Power". Saved with the settings.
public struct RuleSettings: Codable, Equatable, Sendable {
    public var onBattery: RuleActions
    public var lowPowerMode: RuleActions

    public static let `default` = RuleSettings(onBattery: .none, lowPowerMode: .none)

    public init(onBattery: RuleActions, lowPowerMode: RuleActions) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }
}

/// The Mac's power situation, which rules depend on.
public struct PowerContext: Equatable, Sendable {
    public let onBattery: Bool
    public let lowPowerMode: Bool

    public init(onBattery: Bool, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }

    /// This Mac's situation now. Both calls are cheap enough to make every few seconds.
    public static func current() -> PowerContext {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        return PowerContext(
            onBattery: source == kIOPMBatteryPowerKey,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

public enum Rules {
    /// The settings to run with: the person's own, changed by every rule whose condition holds.
    /// The slowest sample rate wins, and hidden modules add up.
    public static func effective(_ settings: PulseSettings, context: PowerContext) -> PulseSettings {
        let rules = settings.rules ?? .default
        var active: [RuleActions] = []
        if context.onBattery { active.append(rules.onBattery) }
        if context.lowPowerMode { active.append(rules.lowPowerMode) }
        guard active.contains(where: { !$0.isEmpty }) else { return settings }

        var result = settings
        let intervals = active.compactMap(\.sampleInterval)
        if let slowest = intervals.max() { result.sampleInterval = max(settings.sampleInterval, slowest) }
        let hidden = active.reduce(into: Set<ModuleKind>()) { $0.formUnion($1.hiddenModules) }
        result.modules = settings.modules.map { module in
            var module = module
            if hidden.contains(module.kind) { module.isEnabled = false }
            return module
        }
        return result
    }
}
