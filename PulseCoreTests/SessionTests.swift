import Foundation
@testable import PulseCore
import Testing

/// The heavy-load recording from `Tools/spikes/throttle` on the M5 Air: 30 s idle, 300 s of
/// floating-point CPU load plus a Metal GPU load, then cooling. Columns as in its header.
private func throttleRecording() throws -> [(time: Date, throttled: Bool)] {
    let text = String(decoding: try Fixture.data("throttle-m5-cpu-gpu-load", "csv"), as: UTF8.self)
    let lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    let header = try #require(lines.first)
    func column(_ name: String) throws -> Int { try #require(header.firstIndex(of: name)) }
    let time = try column("t"), eActive = try column("e_active"), pActive = try column("p_active")
    let eMHz = try column("e_mhz"), pMHz = try column("p_mhz"), hot = try column("chip_hot_c"), state = try column("thermal_state")
    let states: [String: ThermalState] = ["nominal": .nominal, "fair": .fair, "serious": .serious, "critical": .critical]
    return lines.dropFirst().map { row in
        var clusters: [Throttle.Cluster] = []
        for (active, mhz, maximum) in [(eActive, eMHz, 3048e6), (pActive, pMHz, 4464e6)] {
            if let share = Double(row[active]), let frequency = Double(row[mhz]) {
                clusters.append(Throttle.Cluster(activeFraction: share, frequencyHz: frequency * 1e6, maxFrequencyHz: maximum))
            }
        }
        let throttled = Throttle.isThrottled(clusters: clusters, chipCelsius: Double(row[hot]), state: states[row[state]])
        return (Date(timeIntervalSince1970: Double(row[time]) ?? 0), throttled)
    }
}

@Test func heavyLoadOnTheAirIsOneThrottlePeriod() throws {
    let periods = Throttle.periods(try throttleRecording())
    // The load ran from 30 s to 330 s; throttling started 12 s in and lasted until it ended.
    #expect(periods.map { [$0.lowerBound.timeIntervalSince1970, $0.upperBound.timeIntervalSince1970] } == [[42, 329]])
}

@Test func busyButCoolOrIdleButHotIsNotThrottling() {
    let slowBusy = Throttle.Cluster(activeFraction: 1, frequencyHz: 1.4e9, maxFrequencyHz: 4.464e9)
    let fastBusy = Throttle.Cluster(activeFraction: 1, frequencyHz: 3.14e9, maxFrequencyHz: 4.464e9)
    let slowIdle = Throttle.Cluster(activeFraction: 0.1, frequencyHz: 1.3e9, maxFrequencyHz: 4.464e9)
    #expect(Throttle.isThrottled(clusters: [slowBusy], chipCelsius: 85, state: .nominal))
    #expect(Throttle.isThrottled(clusters: [slowBusy], chipCelsius: 60, state: .fair))
    // All-core boost below the single-core maximum, while hot: not throttled.
    #expect(!Throttle.isThrottled(clusters: [fastBusy], chipCelsius: 85, state: .fair))
    // Slow and busy but cool: the chip chose a low frequency, it wasn't forced.
    #expect(!Throttle.isThrottled(clusters: [slowBusy], chipCelsius: 60, state: .nominal))
    // Hot afterwards but idle, as while cooling down.
    #expect(!Throttle.isThrottled(clusters: [slowIdle], chipCelsius: 85, state: .fair))
}

@Test func briefDipsDoNotStartOrSplitAPeriod() {
    let start = Date(timeIntervalSince1970: 0)
    func flags(_ pattern: String) -> [(time: Date, throttled: Bool)] {
        pattern.enumerated().map { (start.addingTimeInterval(TimeInterval($0.offset)), $0.element == "x") }
    }
    // Two throttled seconds aren't enough to start.
    #expect(Throttle.periods(flags("..xx......")).isEmpty)
    // A 5 s dip inside a period doesn't split it; 10 normal seconds end it at the last throttled one.
    let periods = Throttle.periods(flags("xxxxx.....xxxx.........."))
    #expect(periods.map { [$0.lowerBound.timeIntervalSince1970, $0.upperBound.timeIntervalSince1970] } == [[0, 13]])
}

private func sample(_ second: Int, cpu: Double, cpuWatts: Double?, gpuWatts: Double? = nil, chip: Double? = nil) -> SessionSample {
    SessionSample(
        time: Date(timeIntervalSince1970: TimeInterval(second)), cpuUsage: cpu, gpuUsage: nil, cpuWatts: cpuWatts,
        gpuWatts: gpuWatts, systemWatts: nil, efficiencyHz: nil, performanceHz: nil, chipCelsius: chip, thermalState: nil, throttled: false
    )
}

@Test func summaryAveragesPeaksAndEnergy() {
    let samples = (0..<10).map { sample($0, cpu: Double($0) / 10, cpuWatts: 10, gpuWatts: 2, chip: 40 + Double($0)) }
    let summary = SessionCalculations.summary(
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10), samples: samples, processes: []
    )
    #expect(summary.duration == 10)
    #expect(summary.cpuUsage == Stat(average: 0.45, peak: 0.9))
    #expect(summary.cpuWatts == Stat(average: 10, peak: 10))
    // 12 W for ten one-second samples.
    #expect(summary.energyJoules == 120)
    #expect(summary.systemEnergyJoules == nil)
    #expect(summary.peakChipCelsius == 49)
    #expect(summary.gpuUsage == nil)
}

@Test func energySkipsGapsSuchAsSleep() {
    // 100 s between samples counts as 5 s, so sleep adds no energy at the last wattage.
    let samples = [sample(0, cpu: 0.5, cpuWatts: 4), sample(100, cpu: 0.5, cpuWatts: 4)]
    #expect(SessionCalculations.energy(samples) { $0.cpuWatts } == 4 * 5 + 4 * 1)
}

@Test func processTotalsAddUpAcrossScans() {
    let busy = ProcessUsage(
        pid: 7, name: "swift-frontend", cpuCores: 2, footprintBytes: 0, diskReadBytesPerSecond: 0,
        diskWriteBytesPerSecond: 0, energyWatts: 3
    )
    let table = ProcessTable(byCPU: [busy], byMemory: [busy], byDisk: [], byEnergy: [busy], unreadableCount: 0)
    var totals: [Int32: SessionProcess] = [:]
    SessionCalculations.accumulate(&totals, table: table, seconds: 1)
    SessionCalculations.accumulate(&totals, table: table, seconds: 2)
    // Listed in several rankings but counted once per scan: 2 cores for 3 s, 3 W for 3 s.
    #expect(totals[7] == SessionProcess(pid: 7, name: "swift-frontend", cpuSeconds: 6, energyJoules: 9))
}

@Test func recorderSavesASessionWithItsSummary() async throws {
    let database = try HistoryDatabase.inMemory()
    let recorder = SessionRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.start(name: "Build", at: start)
    #expect(await recorder.isRecording)
    let busy = ProcessUsage(
        pid: 7, name: "swift-frontend", cpuCores: 3, footprintBytes: 0, diskReadBytesPerSecond: 0,
        diskWriteBytesPerSecond: 0, energyWatts: 4
    )
    for second in 1...5 {
        var snapshot = Snapshot(timestamp: start.addingTimeInterval(TimeInterval(second)))
        snapshot.cpu = CPUSample(user: 0.5, system: 0.1, cores: [], clusters: [])
        snapshot.power = PowerSample(cpuWatts: 8, clusters: [], gpuWatts: 1, aneWatts: nil, gpuActiveFraction: 0.2, gpuFrequencyHz: nil)
        snapshot.processes = ProcessTable(byCPU: [busy], byMemory: [], byDisk: [], byEnergy: [], unreadableCount: 0)
        await recorder.record(snapshot)
    }
    let session = try #require(try await recorder.stop(at: start.addingTimeInterval(6)))
    #expect(!(await recorder.isRecording))
    #expect(session.samples.count == 5)
    #expect(session.summary.duration == 6)
    #expect(session.summary.energyJoules == 9 * 5)
    // 3 cores for 5 s, the first scan covering the second since the start.
    #expect(session.summary.topProcesses.first?.cpuSeconds == 15)

    let stored = try #require(try database.session(session.id))
    #expect(stored == session)
    #expect(try database.sessions().map(\.name) == ["Build"])
    try database.renameSession(session.id, to: "Release build")
    #expect(try database.sessions().first?.name == "Release build")
    try database.deleteSession(session.id)
    #expect(try database.sessions().isEmpty)
}

@Test func sessionsExportAsJSONAndCSV() throws {
    let samples = [
        SessionSample(
            time: Date(timeIntervalSince1970: 0), cpuUsage: 0.5, gpuUsage: nil, cpuWatts: 12.25, gpuWatts: 0.5, systemWatts: nil,
            efficiencyHz: 2.758e9, performanceHz: 3.14e9, chipCelsius: 77.04, thermalState: .fair, throttled: true
        )
    ]
    let summary = SessionCalculations.summary(
        start: samples[0].time, end: samples[0].time.addingTimeInterval(1), samples: samples, processes: []
    )
    let session = Session(id: UUID(), name: "Build", summary: summary, samples: samples, processes: [])
    let lines = SessionExport.csv(session).split(separator: "\n")
    #expect(lines.first == "time,cpu_usage,gpu_usage,cpu_watts,gpu_watts,system_watts,efficiency_mhz,performance_mhz,chip_celsius,thermal_state,throttled")
    #expect(lines.last == "1970-01-01T00:00:00Z,0.500,,12.250,0.500,,2758,3140,77.0,fair,1")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Session.self, from: SessionExport.json(session)) == session)
}
