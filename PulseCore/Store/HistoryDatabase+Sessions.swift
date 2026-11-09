import Foundation
@_implementationOnly import GRDB

/// A recorded workload session: its summary and one sample per second.
public struct Session: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public let summary: SessionSummary
    public let samples: [SessionSample]
    public let processes: [SessionProcess]

    public init(id: UUID, name: String, summary: SessionSummary, samples: [SessionSample], processes: [SessionProcess]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.samples = samples
        self.processes = processes
    }
}

/// A session in a list, without its samples.
public struct SessionInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let summary: SessionSummary
}

extension HistoryDatabase {
    /// Samples and processes are stored as JSON in the session's row: a session is always read or
    /// exported whole, and an hour of samples is about 700 KB.
    static func createSessionTables(_ db: Database) throws {
        try db.create(table: "sessions") { table in
            table.column("id", .text).primaryKey()
            table.column("name", .text).notNull()
            table.column("start", .double).notNull()
            table.column("summary", .blob).notNull()
            table.column("samples", .blob).notNull()
            table.column("processes", .blob).notNull()
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public func save(_ session: Session) throws {
        let summary = try Self.encoder.encode(session.summary)
        let samples = try Self.encoder.encode(session.samples)
        let processes = try Self.encoder.encode(session.processes)
        try writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sessions (id, name, start, summary, samples, processes) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [session.id.uuidString, session.name, session.summary.start.timeIntervalSince1970, summary, samples, processes]
            )
        }
    }

    /// Newest first.
    public func sessions() throws -> [SessionInfo] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, summary FROM sessions ORDER BY start DESC").compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let summary = try? Self.decoder.decode(SessionSummary.self, from: row["summary"] as Data) else { return nil }
                return SessionInfo(id: id, name: row["name"], summary: summary)
            }
        }
    }

    public func session(_ id: UUID) throws -> Session? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return Session(
                id: id,
                name: row["name"],
                summary: try Self.decoder.decode(SessionSummary.self, from: row["summary"] as Data),
                samples: try Self.decoder.decode([SessionSample].self, from: row["samples"] as Data),
                processes: try Self.decoder.decode([SessionProcess].self, from: row["processes"] as Data)
            )
        }
    }

    public func renameSession(_ id: UUID, to name: String) throws {
        try writer.write { try $0.execute(sql: "UPDATE sessions SET name = ? WHERE id = ?", arguments: [name, id.uuidString]) }
    }

    public func deleteSession(_ id: UUID) throws {
        try writer.write { try $0.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id.uuidString]) }
    }
}
