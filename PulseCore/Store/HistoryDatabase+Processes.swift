import Foundation
@_implementationOnly import GRDB

/// One process in a stored snapshot of the busiest processes.
public struct ProcessSnapshotRow: Sendable, Equatable {
    public let time: Date
    public let pid: Int32
    public let name: String
    /// 1.0 is one full core, as in the process list.
    public let cpuCores: Double
    public let footprintBytes: UInt64
    public let energyWatts: Double

    public init(time: Date, pid: Int32, name: String, cpuCores: Double, footprintBytes: UInt64, energyWatts: Double) {
        self.time = time
        self.pid = pid
        self.name = name
        self.cpuCores = cpuCores
        self.footprintBytes = footprintBytes
        self.energyWatts = energyWatts
    }

    /// The union of the top processes by CPU, memory and energy, each listed once.
    public static func rows(_ table: ProcessTable, at time: Date) -> [ProcessSnapshotRow] {
        var seen = Set<Int32>()
        return (table.byCPU + table.byMemory + table.byEnergy).compactMap { usage in
            guard seen.insert(usage.pid).inserted else { return nil }
            return ProcessSnapshotRow(
                time: time, pid: usage.pid, name: usage.name, cpuCores: usage.cpuCores,
                footprintBytes: usage.footprintBytes, energyWatts: usage.energyWatts
            )
        }
    }
}

/// Process snapshots: every `HistoryStore.processInterval` for 24 h, then each minute's peaks for
/// 30 days. The first table's name dates from a 10 s interval; renaming it would need a migration.
enum ProcessTier: String, CaseIterable {
    case tenSeconds = "processes_10s"
    case minute = "processes_1m"

    var spacing: TimeInterval { self == .tenSeconds ? HistoryStore.processInterval : 60 }
    var retention: TimeInterval { self == .tenSeconds ? 86400 : 30 * 86400 }
}

extension HistoryDatabase {
    /// How many processes per ranking survive into each minute row.
    static let processesPerRanking = 5

    static func createProcessTables(_ db: Database) throws {
        for tier in ProcessTier.allCases {
            try db.create(table: tier.rawValue) { table in
                table.column("t", .double).notNull()
                table.column("pid", .integer).notNull()
                table.column("name", .text).notNull()
                table.column("cpu", .double).notNull()
                table.column("footprint", .integer).notNull()
                table.column("energy", .double).notNull()
                table.primaryKey(["t", "pid"])
            }
        }
    }

    public func insertProcesses(_ rows: [ProcessSnapshotRow]) throws {
        try insertProcesses(rows, into: .tenSeconds)
    }

    /// `into` the minute tier is for tests that fill it directly.
    func insertProcesses(_ rows: [ProcessSnapshotRow], into tier: ProcessTier) throws {
        guard !rows.isEmpty else { return }
        let sql = "INSERT OR REPLACE INTO \(tier.rawValue) (t, pid, name, cpu, footprint, energy) VALUES (?, ?, ?, ?, ?, ?)"
        try writer.write { db in
            let statement = try db.cachedStatement(sql: sql)
            for row in rows {
                try statement.execute(arguments: [
                    row.time.timeIntervalSince1970, row.pid, row.name, row.cpuCores, Int64(clamping: row.footprintBytes), row.energyWatts
                ])
            }
        }
    }

    /// Keeps, for each finished minute, every process's peak values, limited to processes in that
    /// minute's top five by CPU, by memory or by energy. Then prunes both tiers.
    static func rollUpAndPruneProcesses(before now: TimeInterval, _ db: Database) throws {
        let last = try Double.fetchOne(db, sql: "SELECT MAX(t) FROM \(ProcessTier.minute.rawValue)")
        if let first = try last.map({ $0 + 60 }) ?? Double.fetchOne(db, sql: "SELECT MIN(t) FROM \(ProcessTier.tenSeconds.rawValue)") {
            let start = (first / 60).rounded(.down) * 60
            let end = (now / 60).rounded(.down) * 60
            if end > start {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO \(ProcessTier.minute.rawValue) (t, pid, name, cpu, footprint, energy)
                    SELECT minute, pid, name, cpu, footprint, energy FROM (
                        SELECT CAST(t / 60 AS INTEGER) * 60 AS minute, pid, MAX(name) AS name,
                               MAX(cpu) AS cpu, MAX(footprint) AS footprint, MAX(energy) AS energy,
                               ROW_NUMBER() OVER (PARTITION BY CAST(t / 60 AS INTEGER) ORDER BY MAX(cpu) DESC) AS byCPU,
                               ROW_NUMBER() OVER (PARTITION BY CAST(t / 60 AS INTEGER) ORDER BY MAX(footprint) DESC) AS byMemory,
                               ROW_NUMBER() OVER (PARTITION BY CAST(t / 60 AS INTEGER) ORDER BY MAX(energy) DESC) AS byEnergy
                        FROM \(ProcessTier.tenSeconds.rawValue) WHERE t >= ? AND t < ?
                        GROUP BY minute, pid
                    ) WHERE byCPU <= ? OR byMemory <= ? OR byEnergy <= ?
                    """,
                    arguments: [start, end, processesPerRanking, processesPerRanking, processesPerRanking]
                )
            }
        }
        for tier in ProcessTier.allCases {
            try db.execute(sql: "DELETE FROM \(tier.rawValue) WHERE t < ?", arguments: [now - tier.retention])
        }
    }

    /// The stored snapshot nearest before `time`: full snapshots within the last day, minute peaks
    /// before that. Empty when nothing was recorded close to that time, such as during sleep.
    public func processes(at time: Date, now: Date = Date()) throws -> [ProcessSnapshotRow] {
        let tier: ProcessTier = time >= now.addingTimeInterval(-ProcessTier.tenSeconds.retention) ? .tenSeconds : .minute
        let target = time.timeIntervalSince1970
        return try writer.read { db in
            guard let nearest = try Double.fetchOne(
                db,
                sql: "SELECT MAX(t) FROM \(tier.rawValue) WHERE t <= ? AND t > ?",
                arguments: [target, target - 2 * tier.spacing]
            ) else { return [] }
            return try Row.fetchAll(
                db,
                sql: "SELECT pid, name, cpu, footprint, energy FROM \(tier.rawValue) WHERE t = ? ORDER BY cpu DESC",
                arguments: [nearest]
            ).map { row in
                ProcessSnapshotRow(
                    time: Date(timeIntervalSince1970: nearest), pid: row["pid"], name: row["name"], cpuCores: row["cpu"],
                    footprintBytes: UInt64(clamping: row["footprint"] as Int64), energyWatts: row["energy"]
                )
            }
        }
    }

    func processRowCount(_ tier: ProcessTier) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(tier.rawValue)") ?? 0 }
    }
}
