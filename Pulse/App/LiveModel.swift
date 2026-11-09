import Foundation
import Observation
import PulseCore

/// The latest values for the UI. `@Observable` makes SwiftUI views redraw only when a property
/// they read changes, and `@MainActor` keeps all access on the UI thread.
@MainActor
@Observable
final class LiveModel {
    private(set) var snapshot: Snapshot?
    private(set) var history = MetricHistory()
    /// Separate from `snapshot` so that Settings redraws only what actually changed.
    private(set) var selfUsage: SelfUsage?
    private(set) var unavailableModules: Set<ModuleKind> = []
    /// When the current session started, or nil when not recording.
    private(set) var recordingStart: Date?
    /// A running energy total in joules, for "since the panel opened". Uses the Mac's own
    /// cumulative counter when available, otherwise adds up watts over each interval.
    private(set) var energyJoules: Double?
    private var integratedJoules = 0.0
    private var lastPowerTime: Date?

    func setRecordingStart(_ start: Date?) {
        recordingStart = start
    }

    func ingest(_ snapshot: Snapshot, enabled: [ModuleKind]) {
        self.snapshot = snapshot
        history.record(snapshot)
        selfUsage = snapshot.selfUsage
        recordEnergy(snapshot)
        let missing = Set(enabled.filter { ModuleReading.make($0, snapshot: snapshot, recentPeak: 0) == nil })
        // Observers are notified on every assignment, even with an equal value.
        if missing != unavailableModules { unavailableModules = missing }
    }

    private func recordEnergy(_ snapshot: Snapshot) {
        guard let power = snapshot.power, power.cpuWatts != nil else { return }
        defer { lastPowerTime = snapshot.timestamp }
        if let total = power.energySinceBootJoules {
            energyJoules = total
            return
        }
        // Long gaps, such as sleep, are skipped rather than counted at the last wattage.
        if let lastPowerTime {
            let seconds = snapshot.timestamp.timeIntervalSince(lastPowerTime)
            if seconds > 0, seconds < 30 { integratedJoules += power.totalWatts * seconds }
        }
        energyJoules = integratedJoules
    }

    /// Peak of the last minute at the default rate, used to scale unbounded rates.
    func recentPeak(_ series: SeriesID) -> Double {
        history.recentValues(series, count: 60).max() ?? 0
    }
}
