import Foundation
import PulseCore
import Testing

private struct Recorded: Decodable {
    let before: [CPUTicks]
    let after: [CPUTicks]
}

private let m5Levels: [(name: String, count: Int)] = [("Super", 4), ("Efficiency", 6)]
private let m5Types = Array(repeating: "E", count: 6) + Array(repeating: "P", count: 4)

private func close(_ lhs: Double, _ rhs: Double, within: Double = 1e-9) -> Bool {
    abs(lhs - rhs) < within
}

/// Expected values were calculated independently from the recorded ticks.
@Test func recordedM5TicksGiveExpectedLoad() throws {
    let recorded = try JSONDecoder().decode(Recorded.self, from: Fixture.data("cpu-ticks-m5", "json"))
    let names = CPUCalculations.clusterNames(clusterTypes: m5Types, levels: m5Levels)
    let sample = CPUCalculations.sample(previous: recorded.before, current: recorded.after, clusterNames: names)

    #expect(close(sample.user, 0.19193857965451055))
    #expect(close(sample.system, 0.04030710172744722))
    #expect(sample.clusters.map(\.name) == ["Efficiency", "Super"])
    #expect(sample.clusters.map(\.coreCount) == [6, 4])
    #expect(close(sample.clusters[0].usage, 0.38043389997273486))
    #expect(close(sample.clusters[1].usage, 0.009592490842490843))
}

@Test func tickCountersWrapAround() {
    let before = [CPUTicks(user: .max - 9, system: 0, idle: 0, nice: 0)]
    let after = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]
    let sample = CPUCalculations.sample(previous: before, current: after, clusterNames: ["E"])
    #expect(close(sample.total, 0.5))
}

@Test func niceTimeCountsAsUser() {
    let before = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
    let after = [CPUTicks(user: 10, system: 0, idle: 80, nice: 10)]
    let sample = CPUCalculations.sample(previous: before, current: after, clusterNames: ["E"])
    #expect(close(sample.user, 0.2))
}

@Test func noElapsedTicksReadsZero() {
    let ticks = [CPUTicks(user: 5, system: 5, idle: 5, nice: 0)]
    #expect(CPUCalculations.sample(previous: ticks, current: ticks, clusterNames: ["E"]).total == 0)
}

@Test func m5ClustersUseSysctlNames() {
    let names = CPUCalculations.clusterNames(clusterTypes: m5Types, levels: m5Levels)
    #expect(names == Array(repeating: "Efficiency", count: 6) + Array(repeating: "Super", count: 4))
}

@Test func equalSizedClustersMatchSlowestFirst() {
    let names = CPUCalculations.clusterNames(
        clusterTypes: ["E", "E", "P", "P"],
        levels: [("Performance", 2), ("Efficiency", 2)]
    )
    #expect(names == ["Efficiency", "Efficiency", "Performance", "Performance"])
}

@Test func unmatchedClusterFallsBackToRegistryType() {
    #expect(CPUCalculations.clusterNames(clusterTypes: ["E", "E"], levels: [("Performance", 8)]) == ["E", "E"])
}

@Test func missingRegistryAssumesSlowestFirst() {
    #expect(CPUCalculations.clusterNames(levels: [("P", 1), ("E", 2)]) == ["E", "E", "P"])
}
