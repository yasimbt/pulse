import Foundation
// Implementation-only, so that apps and tools linking PulseCore needn't find GRDB's modules.
@_implementationOnly import GRDB

/// A resolution tier of the history. Each is a table with one row per time `t` (seconds since
/// 1970) and one column per `SeriesID`, named by its raw value.
public enum HistoryTier: String, CaseIterable, Sendable {
    case raw = "samples_raw"
    case tenSeconds = "samples_10s"
    case minute = "samples_1m"

    /// Width of an averaged row. Raw rows are single samples.
    var bucket: TimeInterval {
        switch self {
        case .raw: 0
        case .tenSeconds: 10
        case .minute: 60
        }
    }

    /// SPEC §3: raw for 1 h, 10 s averages for 24 h, 1 min averages for 30 days.
    public var retention: TimeInterval {
        switch self {
        case .raw: 3600
        case .tenSeconds: 86400
        case .minute: 30 * 86400
        }
    }

    /// The tier each one is averaged from.
    var source: HistoryTier? {
        switch self {
        case .raw: nil
        case .tenSeconds: .raw
        case .minute: .tenSeconds
        }
    }

    var finer: HistoryTier? { source }
}

/// One sample's values, in SI units.
public struct HistoryRow: Sendable, Equatable {
    public let time: Date
    public let values: [SeriesID: Double]

    public init(time: Date, values: [SeriesID: Double]) {
        self.time = time
        self.values = values
    }

    public init(_ snapshot: Snapshot) {
        time = snapshot.timestamp
        values = Dictionary(uniqueKeysWithValues: SeriesID.allCases.compactMap { id in id.value(in: snapshot).map { (id, $0) } })
    }
}

/// The SQLite history file. All access goes through GRDB, which serialises writes.
/// A class rather than a struct, so that code using PulseCore needn't see GRDB to know its layout.
public final class HistoryDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens or creates the file, in WAL mode so that reads don't wait for writes.
    public static func open(at url: URL) throws -> HistoryDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try HistoryDatabase(writer: DatabasePool(path: url.path))
    }

    /// For tests.
    public static func inMemory() throws -> HistoryDatabase {
        try HistoryDatabase(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Each migration runs once per file, in order. Never edit a shipped migration: add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1: sample tiers") { db in
            for tier in HistoryTier.allCases {
                try db.create(table: tier.rawValue) { table in
                    table.column("t", .double).primaryKey()
                    for id in SeriesID.allCases {
                        table.column(id.rawValue, .double)
                    }
                }
            }
        }
        migrator.registerMigration("v2: process snapshots") { db in
            try createProcessTables(db)
        }
        migrator.registerMigration("v3: sessions") { db in
            try createSessionTables(db)
        }
        return migrator
    }

    // MARK: - Writing

    public func insert(_ rows: [HistoryRow]) throws {
        try insert(rows, into: .raw)
    }

    /// `into` other than raw is for tests that fill the averaged tiers directly.
    func insert(_ rows: [HistoryRow], into tier: HistoryTier) throws {
        guard !rows.isEmpty else { return }
        let columns = SeriesID.allCases
        let names = (["t"] + columns.map { "\"\($0.rawValue)\"" }).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
        let sql = "INSERT OR REPLACE INTO \(tier.rawValue) (\(names)) VALUES (\(placeholders))"
        try writer.write { db in
            let statement = try db.cachedStatement(sql: sql)
            for row in rows {
                let values: [(any DatabaseValueConvertible)?] = [row.time.timeIntervalSince1970] + columns.map { row.values[$0] }
                try statement.execute(arguments: StatementArguments(values))
            }
        }
    }

    /// Averages every completed bucket into the coarser tiers, then deletes rows past retention.
    public func rollUpAndPrune(now: Date) throws {
        let current = now.timeIntervalSince1970
        try writer.write { db in
            for tier in [HistoryTier.tenSeconds, .minute] {
                try Self.rollUp(into: tier, before: current, db)
            }
            for tier in HistoryTier.allCases {
                try db.execute(sql: "DELETE FROM \(tier.rawValue) WHERE t < ?", arguments: [current - tier.retention])
            }
            try Self.rollUpAndPruneProcesses(before: current, db)
        }
    }

    private static func rollUp(into tier: HistoryTier, before now: TimeInterval, _ db: Database) throws {
        guard let source = tier.source else { return }
        let bucket = tier.bucket
        let last = try Double.fetchOne(db, sql: "SELECT MAX(t) FROM \(tier.rawValue)")
        guard let first = try last.map({ $0 + bucket }) ?? Double.fetchOne(db, sql: "SELECT MIN(t) FROM \(source.rawValue)") else {
            return
        }
        let start = (first / bucket).rounded(.down) * bucket
        // Only buckets that have ended, so a bucket is never averaged twice.
        let end = (now / bucket).rounded(.down) * bucket
        guard end > start else { return }
        let names = SeriesID.allCases.map { "\"\($0.rawValue)\"" }
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO \(tier.rawValue) (t, \(names.joined(separator: ", ")))
            SELECT CAST(t / ? AS INTEGER) * ? AS bucket, \(names.map { "AVG(\($0))" }.joined(separator: ", "))
            FROM \(source.rawValue) WHERE t >= ? AND t < ? GROUP BY bucket
            """,
            arguments: [bucket, bucket, start, end]
        )
    }

    // MARK: - Reading

    /// The finest tier still holding data from `start`.
    static func tier(covering start: Date, now: Date) -> HistoryTier {
        HistoryTier.allCases.first { start >= now.addingTimeInterval(-$0.retention) } ?? .minute
    }

    /// Values of one series between two times, oldest first. Uses the finest tier that reaches back
    /// to `start`, then finer tiers for the recent stretch the coarser one hasn't averaged yet.
    public func points(_ id: SeriesID, from start: Date, to end: Date, now: Date = Date()) throws -> [TimedValue] {
        try writer.read { db in
            var points: [TimedValue] = []
            var tier: HistoryTier? = Self.tier(covering: start, now: now)
            var from = start.timeIntervalSince1970
            let until = end.timeIntervalSince1970
            while let current = tier, from <= until {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT t, \"\(id.rawValue)\" AS v FROM \(current.rawValue) WHERE t >= ? AND t <= ? AND v IS NOT NULL ORDER BY t",
                    arguments: [from, until]
                )
                points += rows.map { TimedValue(time: Date(timeIntervalSince1970: $0["t"]), value: $0["v"]) }
                // Continue in the finer tier after this tier's newest row.
                let newest = try Double.fetchOne(db, sql: "SELECT MAX(t) FROM \(current.rawValue)")
                from = max(from, (newest ?? from - current.bucket) + current.bucket)
                tier = current.finer
            }
            return points
        }
    }

    public func rowCount(_ tier: HistoryTier) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(tier.rawValue)") ?? 0 }
    }

    /// Every row's time and value in a tier, oldest first, for tests.
    func column(_ id: SeriesID, in tier: HistoryTier) throws -> [(time: TimeInterval, value: Double?)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT t, \"\(id.rawValue)\" AS v FROM \(tier.rawValue) ORDER BY t").map { ($0["t"], $0["v"]) }
        }
    }

    /// Moves WAL contents into the main file, so that its size on disk is complete.
    func checkpoint() throws {
        try writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    }
}
