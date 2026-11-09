import AppKit
import Observation
import PulseCore
import UniformTypeIdentifiers

/// The sessions window's state: the stored sessions, which are selected, and their full data.
@MainActor
@Observable
final class SessionsModel {
    private let database: HistoryDatabase

    private(set) var sessions: [SessionInfo] = []
    /// One shows its detail; two are compared side by side.
    var selection: Set<UUID> = [] { didSet { loadSelected() } }
    private(set) var loaded: [UUID: Session] = [:]
    private(set) var errorMessage: String?

    init(database: HistoryDatabase) {
        self.database = database
    }

    /// Selected sessions, oldest first, once loaded.
    var selected: [Session] {
        selection.compactMap { loaded[$0] }.sorted { $0.summary.start < $1.summary.start }
    }

    func reload(selecting id: UUID? = nil) {
        sessions = (try? database.sessions()) ?? []
        if let id { selection = [id] }
        selection = selection.filter { id in sessions.contains { $0.id == id } }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? database.renameSession(id, to: trimmed)
        loaded[id]?.name = trimmed
        reload()
    }

    func delete(_ id: UUID) {
        try? database.deleteSession(id)
        loaded[id] = nil
        selection.remove(id)
        reload()
    }

    enum ExportFormat { case json, csv }

    /// Asks where to save, then writes the session.
    func export(_ session: Session, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "\(session.name).\(format == .json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json ? try SessionExport.json(session) : Data(SessionExport.csv(session).utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func loadSelected() {
        for id in selection where loaded[id] == nil {
            loaded[id] = try? database.session(id)
        }
    }
}
