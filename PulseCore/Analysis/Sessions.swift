import Foundation

/// One second of a recorded session, in SI units.
public struct SessionSample: Sendable, Equatable, Codable {
    public let time: Date
    /// 0...1 of all CPU cores.
    public let cpuUsage: Double?
    /// 0...1: share of time the GPU wasn't off.
    public let gpuUsage: Double?
    public let cpuWatts: Double?
    public let gpuWatts: Double?
    /// Whole Mac, from the SMC.
    public let systemWatts: Double?
    public let efficiencyHz: Double?
    public let performanceHz: Double?
    public let chipCelsius: Double?
    public let thermalState: ThermalState?
    public let throttled: Bool

    public init(
        time: Date, cpuUsage: Double?, gpuUsage: Double?, cpuWatts: Double?, gpuWatts: Double?, systemWatts: Double?,
        efficiencyHz: Double?, performanceHz: Double?, chipCelsius: Double?, thermalState: ThermalState?, throttled: Bool
    ) {
        self.time = time
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.systemWatts = systemWatts
        self.efficiencyHz = efficiencyHz
        self.performanceHz = performanceHz
        self.chipCelsius = chipCelsius
        self.thermalState = thermalState
        self.throttled = throttled
    }

    public init(_ snapshot: Snapshot) {
        let power = snapshot.power
        self.init(
            time: snapshot.timestamp,
            cpuUsage: snapshot.cpu?.total,
            gpuUsage: power?.gpuActiveFraction,
            cpuWatts: power?.cpuWatts,
            gpuWatts: power?.gpuWatts,
            systemWatts: snapshot.smc?.systemWatts,
            efficiencyHz: power?.cluster(.efficiency)?.frequencyHz,
            performanceHz: power?.cluster(.performance)?.frequencyHz,
            chipCelsius: snapshot.thermal?.reading("chipHottest")?.celsius,
            thermalState: snapshot.thermal?.state,
            throttled: Throttle.isThrottled(snapshot)
        )
    }
}

/// A process's share of a session: CPU time and energy, summed over the session.
public struct SessionProcess: Sendable, Equatable, Codable {
    public let pid: Int32
    public let name: String
    public let cpuSeconds: Double
    public let energyJoules: Double

    public init(pid: Int32, name: String, cpuSeconds: Double, energyJoules: Double) {
        self.pid = pid
        self.name = name
        self.cpuSeconds = cpuSeconds
        self.energyJoules = energyJoules
    }
}

/// Average and peak of one quantity over a session. Nil when it was never measured.
public struct Stat: Sendable, Equatable, Codable {
    public let average: Double
    public let peak: Double

    public init(average: Double, peak: Double) {
        self.average = average
        self.peak = peak
    }

    static func of(_ values: [Double]) -> Stat? {
        guard let peak = values.max() else { return nil }
        return Stat(average: values.reduce(0, +) / Double(values.count), peak: peak)
    }
}

public struct ThrottlePeriod: Sendable, Equatable, Codable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var seconds: TimeInterval { end.timeIntervalSince(start) + 1 }
}

public struct SessionSummary: Sendable, Equatable, Codable {
    public let start: Date
    public let end: Date
    public let cpuUsage: Stat?
    public let gpuUsage: Stat?
    public let cpuWatts: Stat?
    public let gpuWatts: Stat?
    public let systemWatts: Stat?
    /// CPU plus GPU energy over the session, in joules. The Neural Engine isn't verified yet.
    public let energyJoules: Double
    /// Whole-Mac energy, when the SMC reported power.
    public let systemEnergyJoules: Double?
    public let peakChipCelsius: Double?
    public let worstThermalState: ThermalState?
    public let throttlePeriods: [ThrottlePeriod]
    /// Busiest first, by CPU time.
    public let topProcesses: [SessionProcess]

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var throttledSeconds: TimeInterval { throttlePeriods.reduce(0) { $0 + $1.seconds } }
}

public enum SessionCalculations {
    /// Samples further apart than this, such as across sleep, add no energy for the gap.
    static let maxStep: TimeInterval = 5

    public static func summary(
        start: Date,
        end: Date,
        samples: [SessionSample],
        processes: [SessionProcess],
        topCount: Int = 5
    ) -> SessionSummary {
        let periods = Throttle.periods(samples.map { ($0.time, $0.throttled) }).map {
            ThrottlePeriod(start: $0.lowerBound, end: $0.upperBound)
        }
        let combined = energy(samples) { sample in
            guard let cpu = sample.cpuWatts else { return nil }
            return cpu + (sample.gpuWatts ?? 0)
        }
        let system = samples.contains { $0.systemWatts != nil } ? energy(samples) { $0.systemWatts } : nil
        return SessionSummary(
            start: start,
            end: end,
            cpuUsage: .of(samples.compactMap(\.cpuUsage)),
            gpuUsage: .of(samples.compactMap(\.gpuUsage)),
            cpuWatts: .of(samples.compactMap(\.cpuWatts)),
            gpuWatts: .of(samples.compactMap(\.gpuWatts)),
            systemWatts: .of(samples.compactMap(\.systemWatts)),
            energyJoules: combined,
            systemEnergyJoules: system,
            peakChipCelsius: samples.compactMap(\.chipCelsius).max(),
            worstThermalState: samples.compactMap(\.thermalState).max(),
            throttlePeriods: periods,
            topProcesses: Array(processes.sorted { $0.cpuSeconds > $1.cpuSeconds }.prefix(topCount))
        )
    }

    /// Watts times the time until the next sample, capped at `maxStep`. The last sample counts
    /// for one second.
    static func energy(_ samples: [SessionSample], watts: (SessionSample) -> Double?) -> Double {
        zip(samples.indices, samples).reduce(0) { total, item in
            let (index, sample) = item
            guard let value = watts(sample) else { return total }
            let next = index + 1 < samples.count ? samples[index + 1].time.timeIntervalSince(sample.time) : 1
            return total + value * min(max(next, 0), maxStep)
        }
    }

    /// Adds one process scan's usage to running per-process totals, for `seconds` of time. A scan
    /// lists only the busiest processes, so quieter ones are counted only when they're among them.
    public static func accumulate(
        _ totals: inout [Int32: SessionProcess],
        table: ProcessTable,
        seconds: TimeInterval
    ) {
        var seen = Set<Int32>()
        for usage in table.byCPU + table.byEnergy + table.byMemory where seen.insert(usage.pid).inserted {
            let previous = totals[usage.pid]
            totals[usage.pid] = SessionProcess(
                pid: usage.pid,
                name: usage.name,
                cpuSeconds: (previous?.cpuSeconds ?? 0) + usage.cpuCores * seconds,
                energyJoules: (previous?.energyJoules ?? 0) + usage.energyWatts * seconds
            )
        }
    }
}
