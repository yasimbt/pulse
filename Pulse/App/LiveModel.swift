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

    func ingest(_ snapshot: Snapshot, enabled: [ModuleKind]) {
        self.snapshot = snapshot
        history.record(snapshot)
        selfUsage = snapshot.selfUsage
        let missing = Set(enabled.filter { ModuleReading.make($0, snapshot: snapshot, recentPeak: 0) == nil })
        // Observers are notified on every assignment, even with an equal value.
        if missing != unavailableModules { unavailableModules = missing }
    }

    /// Peak of the last minute at the default rate, used to scale unbounded rates.
    func recentPeak(_ series: SeriesID) -> Double {
        history.recentValues(series, count: 60).max() ?? 0
    }
}
