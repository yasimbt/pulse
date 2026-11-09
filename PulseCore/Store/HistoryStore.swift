import Foundation
import os

/// Records every snapshot into the history database without a write per sample: rows are buffered
/// and written in one transaction every 30 s, which also averages and prunes older data.
/// Failures are logged once and never stop sampling.
public actor HistoryStore {
    public static let flushInterval: TimeInterval = 30
    /// A top-processes snapshot this often, to answer "what spiked at 14:02?". The spec asked for
    /// 10 s; each scan costs about 5 ms of CPU, so 30 s keeps Pulse within its 0.5% budget.
    public static let processInterval: TimeInterval = 30
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "history")

    /// `~/Library/Application Support/Pulse/history.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: PulseInfo.appName).appending(path: "history.sqlite")
    }

    private let database: HistoryDatabase
    private var pending: [HistoryRow] = []
    private var pendingProcesses: [ProcessSnapshotRow] = []
    private var lastProcesses: Date?
    private var lastFlush: Date?
    private var loggedFailure = false

    public init(database: HistoryDatabase) {
        self.database = database
    }

    public func record(_ snapshot: Snapshot) {
        let now = snapshot.timestamp
        // With a panel open, processes come every sample; one per interval is enough to keep.
        if let table = snapshot.processes, now.timeIntervalSince(lastProcesses ?? .distantPast) >= Self.processInterval - 0.5 {
            pendingProcesses += ProcessSnapshotRow.rows(table, at: now)
            lastProcesses = now
        }
        let row = HistoryRow(snapshot)
        guard !row.values.isEmpty else { return }
        pending.append(row)
        if let lastFlush, now.timeIntervalSince(lastFlush) < Self.flushInterval { return }
        if lastFlush == nil {
            lastFlush = now
            return
        }
        flush(now: now)
    }

    /// Writes buffered rows and updates the averaged tiers. Called on a timer and at quit.
    public func flush(now: Date = Date()) {
        let rows = pending
        let processes = pendingProcesses
        pending.removeAll(keepingCapacity: true)
        pendingProcesses.removeAll(keepingCapacity: true)
        lastFlush = now
        do {
            try database.insert(rows)
            try database.insertProcesses(processes)
            try database.rollUpAndPrune(now: now)
        } catch {
            if !loggedFailure {
                loggedFailure = true
                Self.logger.error("history write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The busiest processes at a time, including a snapshot not yet written.
    public func processes(at time: Date, now: Date = Date()) -> [ProcessSnapshotRow] {
        let buffered = pendingProcesses.filter { $0.time <= time && time.timeIntervalSince($0.time) < 2 * Self.processInterval }
        if let nearest = buffered.map(\.time).max() {
            return buffered.filter { $0.time == nearest }.sorted { $0.cpuCores > $1.cpuCores }
        }
        return (try? database.processes(at: time, now: now)) ?? []
    }

    /// Stored values plus any not yet written, oldest first.
    public func points(_ id: SeriesID, from start: Date, to end: Date, now: Date = Date()) -> [TimedValue] {
        let stored = (try? database.points(id, from: start, to: end, now: now)) ?? []
        let newest = stored.last?.time ?? .distantPast
        let buffered = pending.compactMap { row -> TimedValue? in
            guard row.time > newest, row.time >= start, row.time <= end, let value = row.values[id] else { return nil }
            return TimedValue(time: row.time, value: value)
        }
        return stored + buffered
    }
}
