import Foundation
import Observation
import os
import PulseCore

/// What the history window shows: a time range, its loaded series, and the crosshair.
@MainActor
@Observable
final class HistoryModel {
    /// A group of series drawn in one chart.
    struct Group: Identifiable {
        let id: String
        let lines: [(name: String, series: SeriesID)]
        let scale: HistoryScale
    }

    static let groups = [
        Group(id: "CPU", lines: [("Used", .cpuTotal)], scale: .fraction),
        Group(id: "Memory", lines: [("Used", .memoryUsed)], scale: .fraction),
        Group(id: "Power", lines: [("CPU", .powerCPU), ("GPU", .powerGPU)], scale: .watts),
        Group(id: "Network", lines: [("Down", .networkDown), ("Up", .networkUp)], scale: .rate),
        Group(id: "Disk", lines: [("Read", .diskRead), ("Write", .diskWrite)], scale: .rate),
        Group(id: "Battery", lines: [("Charge", .batteryCharge)], scale: .fraction)
    ]

    /// Five minutes up to the 30 days that are kept.
    static let spanRange: ClosedRange<TimeInterval> = 300...(30 * 86400)

    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "history")

    private let store: HistoryStore

    /// Width of the visible range, in seconds.
    var span: TimeInterval = 3600 { didSet { reload() } }
    /// Seconds before now that the visible range ends: 0 follows the present.
    var offset: TimeInterval = 0 { didSet { reload() } }
    var selection: Date? { didSet { loadProcesses() } }

    private(set) var range: ClosedRange<Date> = Date().addingTimeInterval(-3600)...Date()
    /// Thinned for drawing.
    private(set) var drawn: [SeriesID: [TimedValue]] = [:]
    /// Every loaded point, for exact values under the crosshair.
    private(set) var loaded: [SeriesID: [TimedValue]] = [:]
    /// Where no series has data, shaded on every chart.
    private(set) var gaps: [ClosedRange<Date>] = []
    /// Where each series has no data, which is where its line breaks.
    private(set) var seriesGaps: [SeriesID: [ClosedRange<Date>]] = [:]
    private(set) var processes: [ProcessSnapshotRow] = []
    private(set) var isLoading = false
    /// Time to read and prepare the range, shown so that the 300 ms target can be checked.
    private(set) var lastLoadMilliseconds: Double?

    private var loadTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?

    init(store: HistoryStore) {
        self.store = store
        reload()
    }

    var maxGap: TimeInterval { Timeline.gapThreshold(forSpan: span) }

    /// Groups with any data in range; the others aren't drawn.
    var visibleGroups: [Group] {
        Self.groups.filter { group in group.lines.contains { !(drawn[$0.series] ?? []).isEmpty } }
    }

    /// Moves the range by a fraction of its width: negative is earlier. Stops at now and at the
    /// oldest data kept.
    func step(by fraction: Double) {
        offset = (offset - fraction * span).clamped(to: 0...(Self.spanRange.upperBound - span))
    }

    func zoom(by factor: Double) {
        span = (span / factor).clamped(to: Self.spanRange)
    }

    func reload() {
        let end = Date().addingTimeInterval(-offset)
        let range = end.addingTimeInterval(-span)...end
        let maxGap = maxGap
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [store] in
            let clock = ContinuousClock()
            let started = clock.now
            var loaded: [SeriesID: [TimedValue]] = [:]
            for group in Self.groups {
                for line in group.lines {
                    loaded[line.series] = await store.points(line.series, from: range.lowerBound, to: range.upperBound)
                }
            }
            guard !Task.isCancelled else { return }
            let drawn = loaded.mapValues { MetricHistory.downsampled($0, maxCount: Timeline.maxPointsPerSeries) }
            let gaps = Timeline.gaps(in: range, times: loaded.values.flatMap { $0.map(\.time) }, maxGap: maxGap)
            let seriesGaps = loaded.mapValues { Timeline.gaps(in: range, times: $0.map(\.time), maxGap: maxGap) }
            let elapsed = clock.now - started
            self.range = range
            self.loaded = loaded
            self.drawn = drawn
            self.gaps = gaps
            self.seriesGaps = seriesGaps
            self.isLoading = false
            self.lastLoadMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            Self.logger.debug("history load: \(Int(range.upperBound.timeIntervalSince(range.lowerBound))) s in \(elapsed)")
        }
    }

    /// The exact value of a series under the crosshair.
    func value(of series: SeriesID, at time: Date) -> Double? {
        Timeline.value(at: time, in: loaded[series] ?? [], maxGap: maxGap)?.value
    }

    private func loadProcesses() {
        processTask?.cancel()
        guard let selection else {
            processes = []
            return
        }
        processTask = Task { [store] in
            // Waits briefly, so that dragging the crosshair doesn't query on every step.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let rows = await store.processes(at: selection)
            guard !Task.isCancelled else { return }
            processes = rows
        }
    }
}

/// How a history chart's values are scaled and labelled.
enum HistoryScale { case fraction, rate, watts }

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
