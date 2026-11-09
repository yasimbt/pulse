import Foundation

/// Power and frequency for one kind of CPU cluster. Chips with several clusters of a kind, such as
/// two performance clusters, are summed into one.
public struct ClusterPower: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case efficiency
        case performance
    }

    public let kind: Kind
    public let watts: Double
    /// Share of time its cores were running rather than idle, 0...1. Nil when frequencies are off.
    public let activeFraction: Double?
    /// Average frequency while running, in Hz. Nil when this chip's frequency table is unknown.
    public let frequencyHz: Double?
    /// The top of the cluster's frequency table, in Hz, for judging how far it has dropped.
    public let maxFrequencyHz: Double?

    public init(kind: Kind, watts: Double, activeFraction: Double?, frequencyHz: Double?, maxFrequencyHz: Double? = nil) {
        self.kind = kind
        self.watts = watts
        self.activeFraction = activeFraction
        self.frequencyHz = frequencyHz
        self.maxFrequencyHz = maxFrequencyHz
    }
}

/// Watts are averages over the sampling interval.
public struct PowerSample: Sendable, Equatable {
    /// Whole CPU. Nil when no source could be read.
    public let cpuWatts: Double?
    /// Efficiency first, then performance. Empty unless cluster detail was read.
    public let clusters: [ClusterPower]
    public let gpuWatts: Double?
    /// Neural Engine. Not yet checked against powermetrics under an ANE workload.
    public let aneWatts: Double?
    public let gpuActiveFraction: Double?
    public let gpuFrequencyHz: Double?
    /// CPU and GPU energy since the Mac started, from cumulative counters.
    public var energySinceBootJoules: Double?

    public init(
        cpuWatts: Double?,
        clusters: [ClusterPower],
        gpuWatts: Double?,
        aneWatts: Double?,
        gpuActiveFraction: Double?,
        gpuFrequencyHz: Double?,
        energySinceBootJoules: Double? = nil
    ) {
        self.cpuWatts = cpuWatts
        self.clusters = clusters
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.gpuActiveFraction = gpuActiveFraction
        self.gpuFrequencyHz = gpuFrequencyHz
        self.energySinceBootJoules = energySinceBootJoules
    }

    static let empty = PowerSample(cpuWatts: nil, clusters: [], gpuWatts: nil, aneWatts: nil, gpuActiveFraction: nil, gpuFrequencyHz: nil)

    /// CPU and GPU. The Neural Engine is left out until its counter is checked against
    /// powermetrics, and memory and the rest of the system aren't reported without root.
    /// See docs/m2-findings.md.
    public var totalWatts: Double { (cpuWatts ?? 0) + (gpuWatts ?? 0) }

    public func cluster(_ kind: ClusterPower.Kind) -> ClusterPower? {
        clusters.first { $0.kind == kind }
    }
}

public struct TemperatureReading: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let celsius: Double

    public init(id: String, title: String, celsius: Double) {
        self.id = id
        self.title = title
        self.celsius = celsius
    }
}

/// macOS's own thermal pressure, from `ProcessInfo.thermalState`. Coarse and slow to change:
/// on the M5 Air it reached "fair" about a minute into throttling. See docs/m4-findings.md.
public enum ThermalState: Int, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

public struct ThermalSample: Sendable, Equatable {
    /// In the sensor map's order.
    public let readings: [TemperatureReading]
    public let state: ThermalState?

    public init(readings: [TemperatureReading], state: ThermalState? = nil) {
        self.readings = readings
        self.state = state
    }

    public func reading(_ id: String) -> TemperatureReading? {
        readings.first { $0.id == id }
    }
}

public struct FanReading: Sendable, Equatable, Identifiable {
    public let index: Int
    public let rpm: Double
    public let minimumRPM: Double?
    public let maximumRPM: Double?

    public var id: Int { index }

    public init(index: Int, rpm: Double, minimumRPM: Double?, maximumRPM: Double?) {
        self.index = index
        self.rpm = rpm
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }
}

public struct SMCSample: Sendable, Equatable {
    /// Whole-system power (SMC key PSTR): CPU, GPU, display, memory, storage and the rest. An
    /// instantaneous reading, so it jumps more than the averaged CPU and GPU figures.
    public let systemWatts: Double?
    /// Empty on a fanless Mac.
    public let fans: [FanReading]

    public init(systemWatts: Double?, fans: [FanReading]) {
        self.systemWatts = systemWatts
        self.fans = fans
    }
}
