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

    public init(kind: Kind, watts: Double, activeFraction: Double?, frequencyHz: Double?) {
        self.kind = kind
        self.watts = watts
        self.activeFraction = activeFraction
        self.frequencyHz = frequencyHz
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
