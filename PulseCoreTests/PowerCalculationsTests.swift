import Foundation
@testable import PulseCore
import Testing

/// Recorded on the M5 with `Tools/spikes/ioreport` (`ior dump 2`): idle, and with 4 busy loops.
/// Expected values were computed separately in Python from the same files.
private struct PowerFixture: Decodable {
    let seconds: Double
    let readings: [IOReportReading]
    let voltageStates: [String: [UInt32]]

    static func load(_ name: String) throws -> PowerFixture {
        try JSONDecoder().decode(PowerFixture.self, from: Fixture.data(name, "json"))
    }

    var sample: PowerSample {
        PowerCalculations.sample(readings, seconds: seconds, tables: FrequencyTables(voltageStates: voltageStates))
    }
}

private func close(_ value: Double?, _ expected: Double, relative: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= abs(expected) * relative
}

@Test func frequencyTablesMatchPowermetricsOnM5() throws {
    let tables = FrequencyTables(voltageStates: try PowerFixture.load("ioreport-power-m5-idle").voltageStates)
    #expect(tables.efficiency.count == 8)
    #expect(tables.efficiency.first == 972e6 && tables.efficiency.last == 3048e6)
    #expect(tables.performance.count == 19)
    #expect(tables.performance.first == 1308e6 && tables.performance.last == 4464e6)
    // The GPU table starts with a zero entry for its off state, which is dropped.
    #expect(tables.gpu.count == 12)
    #expect(tables.gpu.first == 338e6 && tables.gpu.last == 1578e6)
}

@Test func frequencyTableWordsAreFrequencyVoltagePairs() {
    let words: [UInt32] = [972_000, 700, 1_152_000, 750]
    let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
    #expect(FrequencyTables.words(data) == words)
    #expect(FrequencyTables.frequencies(words) == [972e6, 1152e6])
    #expect(FrequencyTables.frequencies([0, 0, 338_000_000, 600]) == [338e6])
}

@Test func histogramChargesEachEventAtItsBucketMidpoint() {
    let states = [
        IOReportReading.State(name: " 0.250W", value: 4),
        IOReportReading.State(name: " 0.500W", value: 2),
        IOReportReading.State(name: " 0.750W", value: 0)
    ]
    // Step 0.25 W: midpoints 0.125 and 0.375.
    let expected = (0.125 * 4 + 0.375 * 2) * PowerCalculations.eventSeconds
    #expect(close(PowerCalculations.histogramJoules(states), expected))
    #expect(PowerCalculations.histogramJoules([]) == 0)
    #expect(PowerCalculations.bucketWatts("  16W") == 16)
    #expect(PowerCalculations.bucketWatts("IDLE") == nil)
}

@Test func loadFixtureGivesPerformanceClusterWatts() throws {
    let sample = try PowerFixture.load("ioreport-power-m5-load").sample
    let efficiency = try #require(sample.cluster(.efficiency))
    let performance = try #require(sample.cluster(.performance))
    #expect(close(efficiency.watts, 0.113578557, relative: 1e-8))
    #expect(close(performance.watts, 18.298010987, relative: 1e-8))
    #expect(close(performance.activeFraction, 1.0))
    #expect(close(performance.frequencyHz, 4464e6))
    #expect(close(efficiency.frequencyHz, 1955286228.8068905))
    #expect(close(sample.gpuWatts, 0.0108963225))
    #expect(close(sample.gpuFrequencyHz, 338e6))
    #expect(close(sample.cpuWatts, 0.113578557 + 18.298010987, relative: 1e-8))
}

@Test func idleFixtureGivesSmallWatts() throws {
    let sample = try PowerFixture.load("ioreport-power-m5-idle").sample
    #expect(close(sample.cluster(.efficiency)?.watts, 0.075139458, relative: 1e-8))
    #expect(close(sample.cluster(.performance)?.watts, 0.092631180, relative: 1e-8))
    #expect(close(sample.cluster(.performance)?.activeFraction, 0.0029164428003859272))
    #expect(close(sample.cluster(.performance)?.frequencyHz, 2720377323.15305))
    #expect(close(sample.gpuActiveFraction, 0.03670532460002144))
    #expect(sample.totalWatts < 0.5)
}

@Test func mismatchedFrequencyTableHidesFrequencyButKeepsWatts() throws {
    let fixture = try PowerFixture.load("ioreport-power-m5-load")
    // A table with the wrong number of states, as on a chip whose registry keys differ.
    let wrong = FrequencyTables(efficiency: [1e9, 2e9], performance: [1e9], gpu: [])
    let sample = PowerCalculations.sample(fixture.readings, seconds: fixture.seconds, tables: wrong)
    #expect(sample.cluster(.performance)?.frequencyHz == nil)
    #expect(sample.cluster(.efficiency)?.frequencyHz == nil)
    #expect(sample.gpuFrequencyHz == nil)
    #expect(close(sample.cluster(.performance)?.watts, 18.298010987, relative: 1e-8))
}

@Test func zeroIntervalGivesAnEmptySample() throws {
    let fixture = try PowerFixture.load("ioreport-power-m5-load")
    let sample = PowerCalculations.sample(fixture.readings, seconds: 0, tables: FrequencyTables(voltageStates: [:]))
    #expect(sample.clusters.isEmpty)
    #expect(sample.gpuWatts == nil)
}

/// Recorded with `Tools/spikes/clpc` on the M5 with 4 busy loops: one 1.004 s interval.
private let clpcLoad = [
    IOReportReading(group: "CLPC", subgroup: "Energy Counters", channel: "CPU Energy", unit: "nJ", value: 18_184_058_512),
    IOReportReading(group: "CLPC", subgroup: "Energy Counters", channel: "GPU Energy", unit: "nJ", value: 310_377),
    IOReportReading(group: "CLPC", subgroup: "Energy Counters", channel: "ANE", unit: "nJ", value: 0)
]

@Test func clpcCountersGiveWholeCPUWatts() {
    let sample = PowerCalculations.sample(clpcLoad, seconds: 1.004, tables: FrequencyTables(voltageStates: [:]))
    #expect(close(sample.cpuWatts, 18.184058512 / 1.004))
    #expect(close(sample.gpuWatts, 0.000310377 / 1.004))
    #expect(sample.aneWatts == 0)
    #expect(sample.clusters.isEmpty)
}

@Test func clpcTotalTakesPrecedenceOverClusterSum() throws {
    let fixture = try PowerFixture.load("ioreport-power-m5-load")
    let sample = PowerCalculations.sample(
        fixture.readings + clpcLoad, seconds: fixture.seconds, tables: FrequencyTables(voltageStates: fixture.voltageStates)
    )
    #expect(close(sample.cpuWatts, 18.184058512 / fixture.seconds))
    // CLPC's GPU counter is preferred over Energy Model's.
    #expect(close(sample.gpuWatts, 0.000310377 / fixture.seconds))
    #expect(close(sample.cluster(.performance)?.watts, 18.298010987, relative: 1e-8))
}

@Test func clpcChannelsNeedAKnownMacOSVersion() {
    #expect(CLPCChannels.channels(osMajorVersion: 26) == nil)
    #expect(CLPCChannels.channels(osMajorVersion: 28) == nil)
}
