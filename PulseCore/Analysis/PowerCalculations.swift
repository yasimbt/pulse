import Foundation

/// One IOReport channel's change over a sampling interval, copied out of Core Foundation so that
/// calculations can be tested with recorded fixtures.
public struct IOReportReading: Sendable, Equatable, Codable {
    public struct State: Sendable, Equatable, Codable {
        public let name: String
        public let value: Int64

        public init(name: String, value: Int64) {
            self.name = name
            self.value = value
        }
    }

    public let group: String
    /// Empty when the channel has none.
    public let subgroup: String
    public let channel: String
    public let unit: String
    /// Simple channels: a counter delta.
    public let value: Int64?
    /// State channels: time or event count per state.
    public let states: [State]?

    public init(group: String, subgroup: String, channel: String, unit: String, value: Int64? = nil, states: [State]? = nil) {
        self.group = group
        self.subgroup = subgroup
        self.channel = channel
        self.unit = unit
        self.value = value
        self.states = states
    }
}

/// DVFS tables from the `pmgr` IORegistry node, in Hz, lowest first.
public struct FrequencyTables: Sendable, Equatable {
    public let efficiency: [Double]
    public let performance: [Double]
    public let gpu: [Double]

    /// Registry keys confirmed against powermetrics on the M5. Other chips are unverified, and a
    /// table whose length doesn't match the residency states is ignored.
    public static let keys = (efficiency: "voltage-states1-sram", performance: "voltage-states5-sram", gpu: "voltage-states9")

    public init(efficiency: [Double], performance: [Double], gpu: [Double]) {
        self.efficiency = efficiency
        self.performance = performance
        self.gpu = gpu
    }

    public init(voltageStates: [String: [UInt32]]) {
        efficiency = Self.frequencies(voltageStates[Self.keys.efficiency] ?? [])
        performance = Self.frequencies(voltageStates[Self.keys.performance] ?? [])
        gpu = Self.frequencies(voltageStates[Self.keys.gpu] ?? [])
    }

    /// Entries are (frequency, voltage) pairs. CPU tables are in kHz and the GPU table in Hz, so
    /// small values are scaled. Zero entries, such as the GPU's off state, are dropped.
    static func frequencies(_ words: [UInt32]) -> [Double] {
        stride(from: 0, to: words.count - 1, by: 2)
            .map { Double(words[$0]) }
            .filter { $0 > 0 }
            .map { $0 < 10_000_000 ? $0 * 1000 : $0 }
    }

    public static func words(_ data: Data) -> [UInt32] {
        data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}

public enum PowerCalculations {
    /// Time covered by one PMP energy event. Both CPU clusters record at most about 4,399 events
    /// per second when busy (52,790 in 12 s). Calibrated against powermetrics on the M5.
    public static let eventSeconds = 12.0 / 52_790.0

    private static let inactiveStates: Set<String> = ["IDLE", "OFF", "DOWN"]

    public static func sample(_ readings: [IOReportReading], seconds: Double, tables: FrequencyTables) -> PowerSample {
        guard seconds > 0 else { return .empty }
        let (joules, coreStates, energy, gpuStates) = sorted(readings)
        let clusters = [ClusterPower.Kind.efficiency, .performance].compactMap { kind -> ClusterPower? in
            guard joules[kind] != nil || coreStates[kind] != nil else { return nil }
            let table = kind == .efficiency ? tables.efficiency : tables.performance
            let residency = residency(coreStates[kind] ?? [], table: table)
            return ClusterPower(
                kind: kind,
                watts: (joules[kind] ?? 0) / seconds,
                activeFraction: coreStates[kind] == nil ? nil : residency.activeFraction,
                frequencyHz: residency.frequencyHz
            )
        }
        let gpu = gpuStates.map { residency([$0], table: tables.gpu, allowLongerStates: true) }
        // CLPC's aggregate counter when read; otherwise the clusters' sum.
        let clusterCPU = joules.isEmpty ? nil : clusters.reduce(0) { $0 + $1.watts }
        return PowerSample(
            cpuWatts: energy.cpu.map { $0 / seconds } ?? clusterCPU,
            clusters: clusters,
            gpuWatts: (energy.clpcGPU ?? energy.modelGPU).map { $0 / seconds },
            aneWatts: energy.ane.map { $0 / seconds },
            gpuActiveFraction: gpu?.activeFraction,
            gpuFrequencyHz: gpu?.frequencyHz
        )
    }

    private typealias Sorted = (
        joules: [ClusterPower.Kind: Double],
        coreStates: [ClusterPower.Kind: [[IOReportReading.State]]],
        energy: Counters,
        gpuStates: [IOReportReading.State]?
    )

    /// Joules from simple energy counters.
    private struct Counters {
        var cpu: Double?
        var clpcGPU: Double?
        var modelGPU: Double?
        var ane: Double?

        /// Returns false for a channel that isn't an energy counter used here.
        mutating func add(_ reading: IOReportReading) -> Bool {
            let joules = PowerCalculations.joules
            switch (reading.group, reading.subgroup, reading.channel) {
            case ("Energy Model", _, "GPU Energy"): modelGPU = joules(reading)
            case (CLPCChannels.group, CLPCChannels.subgroup, "CPU Energy"): cpu = joules(reading)
            case (CLPCChannels.group, CLPCChannels.subgroup, "GPU Energy"): clpcGPU = joules(reading)
            case (CLPCChannels.group, CLPCChannels.subgroup, "ANE"): ane = joules(reading)
            default: return false
            }
            return true
        }
    }

    /// Picks out the channels power is calculated from.
    private static func sorted(_ readings: [IOReportReading]) -> Sorted {
        var result: Sorted = ([:], [:], Counters(), nil)
        for reading in readings where !result.energy.add(reading) {
            switch (reading.group, reading.subgroup) {
            case ("PMP", "Energy"):
                if let kind = clusterKind(energyChannel: reading.channel), let states = reading.states {
                    result.joules[kind, default: 0] += histogramJoules(states)
                }
            case ("CPU Stats", "CPU Core Performance States"):
                if let kind = clusterKind(coreChannel: reading.channel), let states = reading.states {
                    result.coreStates[kind, default: []].append(states)
                }
            case ("GPU Stats", "GPU Performance States") where reading.channel == "GPUPH":
                result.gpuStates = reading.states
            default:
                break
            }
        }
        return result
    }

    /// Joules from one PMP energy histogram. Each state is a power bucket labelled with the top
    /// of its range, such as "16W", and counts events. Each event is charged at the bucket's midpoint.
    public static func histogramJoules(_ states: [IOReportReading.State]) -> Double {
        let buckets = states.compactMap { state -> (watts: Double, count: Double)? in
            bucketWatts(state.name).map { ($0, Double(state.value)) }
        }
        let levels = Set(buckets.map(\.watts)).filter { $0 > 0 }.sorted()
        let step = zip(levels.dropFirst(), levels).map { $0 - $1 }.min() ?? 0
        let weighted = buckets.reduce(0) { $0 + max(0, $1.watts - step / 2) * $1.count }
        return weighted * eventSeconds
    }

    static func bucketWatts(_ label: String) -> Double? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("W") else { return nil }
        return Double(trimmed.dropLast())
    }

    /// Residency-weighted average frequency over every core given, while running. The table is
    /// used only when it has one entry per running state, unless `allowLongerStates` lets extra
    /// states at the top go unmapped, as the GPU reports more states than its table lists.
    static func residency(
        _ cores: [[IOReportReading.State]],
        table: [Double],
        allowLongerStates: Bool = false
    ) -> (activeFraction: Double, frequencyHz: Double?) {
        var total = 0.0, active = 0.0, mapped = 0.0, weighted = 0.0
        var tableFits = !table.isEmpty
        for states in cores {
            let running = states.filter { !inactiveStates.contains($0.name) }
            if running.count < table.count || (!allowLongerStates && running.count != table.count) {
                tableFits = false
            }
            total += states.reduce(0) { $0 + Double($1.value) }
            active += running.reduce(0) { $0 + Double($1.value) }
            for (state, frequency) in zip(running, table) {
                mapped += Double(state.value)
                weighted += Double(state.value) * frequency
            }
        }
        let fraction = total > 0 ? active / total : 0
        let frequency = tableFits && mapped > 0 ? weighted / mapped : nil
        return (fraction, frequency)
    }

    static func clusterKind(energyChannel name: String) -> ClusterPower.Kind? {
        if name.hasPrefix("EACC") { return .efficiency }
        if name.hasPrefix("PACC") { return .performance }
        return nil
    }

    static func clusterKind(coreChannel name: String) -> ClusterPower.Kind? {
        if name.hasPrefix("ECPU") { return .efficiency }
        if name.hasPrefix("PCPU") { return .performance }
        return nil
    }

    fileprivate static func joules(_ reading: IOReportReading) -> Double? {
        guard let value = reading.value, let scale = jouleScale(reading.unit) else { return nil }
        return Double(value) * scale
    }

    static func jouleScale(_ unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": 1
        case "mJ": 1e-3
        case "uJ": 1e-6
        case "nJ": 1e-9
        default: nil
        }
    }
}
