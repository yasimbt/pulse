import Foundation
import os

/// Records every snapshot into the history database without a write per sample: rows are buffered
/// and written in one transaction every 30 s, which also averages and prunes older data.
/// Failures are logged once and never stop sampling.
public actor HistoryStore {
    public static let flushInterval: TimeInterval = 30
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "history")

    /// `~/Library/Application Support/Pulse/history.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: PulseInfo.appName).appending(path: "history.sqlite")
    }

    private let database: HistoryDatabase
    private var pending: [HistoryRow] = []
    private var lastFlush: Date?
    private var loggedFailure = false

    public init(database: HistoryDatabase) {
        self.database = database
    }

    public func record(_ snapshot: Snapshot) {
        let row = HistoryRow(snapshot)
        guard !row.values.isEmpty else { return }
        pending.append(row)
        let now = snapshot.timestamp
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
        pending.removeAll(keepingCapacity: true)
        lastFlush = now
        do {
            try database.insert(rows)
            try database.rollUpAndPrune(now: now)
        } catch {
            if !loggedFailure {
                loggedFailure = true
                Self.logger.error("history write failed: \(String(describing: error), privacy: .public)")
            }
        }
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
