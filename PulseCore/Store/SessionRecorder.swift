import Foundation

/// Records a workload session: one sample per second while it runs, plus per-process totals, then
/// a summary saved to the history database when it stops.
public actor SessionRecorder {
    private struct Recording {
        let id: UUID
        let name: String
        let start: Date
        var samples: [SessionSample] = []
        var processes: [Int32: SessionProcess] = [:]
        var lastProcessScan: Date?
    }

    private let database: HistoryDatabase
    private var recording: Recording?

    public init(database: HistoryDatabase) {
        self.database = database
    }

    public var isRecording: Bool { recording != nil }

    /// Starts a session. The name defaults to its start time, such as "Session 9 Nov at 22:40".
    @discardableResult
    public func start(name: String? = nil, at time: Date = Date()) -> Date {
        if let recording { return recording.start }
        let title = name ?? "Session \(time.formatted(.dateTime.day().month(.abbreviated))) at \(time.formatted(.dateTime.hour().minute()))"
        recording = Recording(id: UUID(), name: title, start: time)
        return time
    }

    public func record(_ snapshot: Snapshot) {
        guard var current = recording, snapshot.timestamp >= current.start else { return }
        current.samples.append(SessionSample(snapshot))
        if let table = snapshot.processes {
            // The usage in a scan is the average since the scan before, so that's the time it covers.
            let since = current.lastProcessScan ?? current.start
            let seconds = min(max(snapshot.timestamp.timeIntervalSince(since), 0), SessionCalculations.maxStep)
            SessionCalculations.accumulate(&current.processes, table: table, seconds: seconds)
            current.lastProcessScan = snapshot.timestamp
        }
        recording = current
    }

    /// Ends the session, saves it, and returns it. Nil when nothing was recording.
    @discardableResult
    public func stop(at time: Date = Date()) throws -> Session? {
        guard let current = recording else { return nil }
        recording = nil
        let processes = current.processes.values.sorted { $0.cpuSeconds > $1.cpuSeconds }
        let session = Session(
            id: current.id,
            name: current.name,
            summary: SessionCalculations.summary(start: current.start, end: time, samples: current.samples, processes: processes),
            samples: current.samples,
            processes: processes
        )
        try database.save(session)
        return session
    }
}
