import Foundation
@testable import PulseCore
import Testing

/// Divisible by 60, so buckets line up with whole minutes.
private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func row(_ second: Int, cpu: Double, memory: Double? = nil) -> HistoryRow {
    var values: [SeriesID: Double] = [.cpuTotal: cpu]
    values[.memoryUsed] = memory
    return HistoryRow(time: origin.addingTimeInterval(TimeInterval(second)), values: values)
}

@Test func rawRowsReadBackInOrder() throws {
    let database = try HistoryDatabase.inMemory()
    try database.insert([row(2, cpu: 0.3), row(0, cpu: 0.1), row(1, cpu: 0.2, memory: 0.5)])
    let now = origin.addingTimeInterval(5)
    let cpu = try database.points(.cpuTotal, from: origin, to: now, now: now)
    #expect(cpu.map(\.value) == [0.1, 0.2, 0.3])
    // A metric that wasn't recorded at a time has no point there, rather than a zero.
    #expect(try database.points(.memoryUsed, from: origin, to: now, now: now).map(\.value) == [0.5])
}

@Test func completedBucketsAreAveragedOnce() throws {
    let database = try HistoryDatabase.inMemory()
    // One sample a second for 125 s; cpu equals the second number / 100.
    try database.insert((0..<125).map { row($0, cpu: Double($0) / 100) })
    try database.rollUpAndPrune(now: origin.addingTimeInterval(125))
    // 10 s buckets that have ended: 0-10 ... 110-120.
    #expect(try database.rowCount(.tenSeconds) == 12)
    // 1 min buckets whose 10 s averages exist: 0-60 and 60-120.
    #expect(try database.rowCount(.minute) == 2)
    let tens = try database.column(.cpuTotal, in: .tenSeconds)
    #expect(abs((tens[0].value ?? 0) - 0.045) < 1e-9)
    let minutes = try database.column(.cpuTotal, in: .minute)
    #expect(abs((minutes[1].value ?? 0) - 0.895) < 1e-9)

    // Running again later adds only the newly completed buckets.
    try database.insert((125..<130).map { row($0, cpu: 1) })
    try database.rollUpAndPrune(now: origin.addingTimeInterval(131))
    #expect(try database.rowCount(.tenSeconds) == 13)
    let last = try database.column(.cpuTotal, in: .tenSeconds).first { $0.time == 1_800_000_120 }
    #expect(abs((last?.value ?? 0) - (1.2 + 1.21 + 1.22 + 1.23 + 1.24 + 5) / 10) < 1e-9)
}

@Test func rowsPastRetentionArePruned() throws {
    let database = try HistoryDatabase.inMemory()
    try database.insert([row(0, cpu: 0.1), row(3_000, cpu: 0.2)])
    try database.rollUpAndPrune(now: origin.addingTimeInterval(3_700))
    // Raw keeps one hour: the first row is gone, but its average lives on in the coarser tiers.
    #expect(try database.column(.cpuTotal, in: .raw).map(\.time) == [1_800_003_000])
    #expect(try database.rowCount(.tenSeconds) == 2)
}

@Test func readsUseTheCoarserTierThenFillTheRecentGapFromRaw() throws {
    let database = try HistoryDatabase.inMemory()
    try database.insert((0..<7_300).map { row($0, cpu: 0.5) })
    let now = origin.addingTimeInterval(7_300)
    try database.rollUpAndPrune(now: now)
    try database.insert([row(7_300, cpu: 0.9)])
    // Two hours back is beyond raw's hour, so 10 s averages are used, with raw for the newest row.
    let points = try database.points(.cpuTotal, from: origin.addingTimeInterval(200), to: now, now: now)
    #expect(points.count == 710 + 1)
    #expect(points.last?.value == 0.9)
    #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
}

@Test func tierChoiceFollowsRetention() {
    let now = origin
    #expect(HistoryDatabase.tier(covering: now.addingTimeInterval(-600), now: now) == .raw)
    #expect(HistoryDatabase.tier(covering: now.addingTimeInterval(-7_200), now: now) == .tenSeconds)
    #expect(HistoryDatabase.tier(covering: now.addingTimeInterval(-3 * 86_400), now: now) == .minute)
    #expect(HistoryDatabase.tier(covering: now.addingTimeInterval(-90 * 86_400), now: now) == .minute)
}

@Test func storeBuffersUntilTheFlushInterval() async throws {
    let database = try HistoryDatabase.inMemory()
    let store = HistoryStore(database: database)
    for second in 0..<30 {
        var snapshot = Snapshot(timestamp: origin.addingTimeInterval(TimeInterval(second)))
        snapshot.selfUsage = nil
        await store.record(withCPU(snapshot, 0.25))
    }
    #expect(try database.rowCount(.raw) == 0)
    // Buffered rows are still readable.
    let now = origin.addingTimeInterval(30)
    #expect(await store.points(.cpuTotal, from: origin, to: now, now: now).count == 30)
    await store.record(withCPU(Snapshot(timestamp: now), 0.25))
    #expect(try database.rowCount(.raw) == 31)
}

private func withCPU(_ snapshot: Snapshot, _ total: Double) -> Snapshot {
    var snapshot = snapshot
    snapshot.cpu = CPUSample(user: total, system: 0, cores: [], clusters: [])
    return snapshot
}

/// Acceptance (M3): under 200 MB after 30 days at default settings. Fills every tier to its
/// retention with every series set, which is more than a real Mac records, and measures the file.
@Test func thirtyDaysOfHistoryStayFarUnder200MB() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "pulse-size-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: url.lastPathComponent)) }
    let database = try HistoryDatabase.open(at: url)
    let now = origin.addingTimeInterval(30 * 86_400)
    let all = Dictionary(uniqueKeysWithValues: SeriesID.allCases.map { ($0, 123_456.789) })
    for tier in HistoryTier.allCases {
        let step: TimeInterval = tier == .raw ? 1 : (tier == .tenSeconds ? 10 : 60)
        let count = Int(tier.retention / step)
        let rows = (0..<count).map { HistoryRow(time: now.addingTimeInterval(-Double(count - $0) * step), values: all) }
        try database.insert(rows, into: tier)
    }
    try database.checkpoint()
    let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    #expect(bytes > 0)
    #expect(bytes < 200_000_000)
    print("30-day history file: \(bytes / 1_000_000) MB")
}
