public enum ModuleKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpu, memory, disk, network, battery, power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .battery: "Battery"
        case .power: "Power"
        }
    }

    /// Short prefix in the menu bar, so that modules are never told apart by colour alone.
    public var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .disk: "DSK"
        case .network: "NET"
        case .battery: "BAT"
        case .power: "PWR"
        }
    }
}

public enum RendererKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case text, sparkline, bar, gauge

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// `.system` follows the menu bar's own light or dark appearance.
public enum ModuleTint: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, blue, green, orange, red, purple, teal

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ModuleConfig: Codable, Equatable, Sendable, Identifiable {
    public var kind: ModuleKind
    public var isEnabled: Bool
    public var renderer: RendererKind
    public var tint: ModuleTint

    public var id: ModuleKind { kind }

    public init(kind: ModuleKind, isEnabled: Bool, renderer: RendererKind = .text, tint: ModuleTint = .system) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.renderer = renderer
        self.tint = tint
    }
}

public struct PulseSettings: Codable, Equatable, Sendable {
    public static let sampleIntervals: [Double] = [0.5, 1, 2, 5]

    /// Array order is menu-bar order, left to right.
    public var modules: [ModuleConfig]
    public var sampleInterval: Double
    public var isCombined: Bool

    public init(modules: [ModuleConfig], sampleInterval: Double, isCombined: Bool) {
        self.modules = modules
        self.sampleInterval = sampleInterval
        self.isCombined = isCombined
    }

    public static let `default` = PulseSettings(
        modules: [
            ModuleConfig(kind: .cpu, isEnabled: true, renderer: .sparkline),
            ModuleConfig(kind: .power, isEnabled: true, renderer: .text),
            ModuleConfig(kind: .memory, isEnabled: true, renderer: .bar),
            ModuleConfig(kind: .network, isEnabled: true, renderer: .text),
            ModuleConfig(kind: .disk, isEnabled: false, renderer: .text),
            ModuleConfig(kind: .battery, isEnabled: false, renderer: .text)
        ],
        sampleInterval: 1,
        isCombined: false
    )

    public var enabledModules: [ModuleConfig] {
        modules.filter(\.isEnabled)
    }

    /// Repairs settings saved by another version: drops duplicates and unknown state, appends
    /// any new module as disabled, and pulls the interval into the allowed range.
    public func normalized() -> PulseSettings {
        var seen = Set<ModuleKind>()
        var result = modules.filter { seen.insert($0.kind).inserted }
        for kind in ModuleKind.allCases where !seen.contains(kind) {
            result.append(ModuleConfig(kind: kind, isEnabled: false))
        }
        return PulseSettings(
            modules: result,
            sampleInterval: sampleInterval.clamped(to: Sampler.intervalRange),
            isCombined: isCombined
        )
    }
}
