import Foundation

/// Pure helpers for the history timeline: gaps, line segments, values at a time, and thinning.
public enum Timeline {
    /// Ranges the timeline offers, shortest first.
    public static let spans: [TimeInterval] = [3600, 6 * 3600, 86400, 7 * 86400, 30 * 86400]

    /// Points are drawn at most this many per series; more add cost but no visible detail.
    public static let maxPointsPerSeries = 600

    /// The longest step between points that still counts as continuous. Wider steps are gaps, when
    /// the Mac was asleep or Pulse wasn't running. Depends on the tier the range is read from.
    public static func gapThreshold(forSpan span: TimeInterval) -> TimeInterval {
        if span <= HistoryTier.raw.retention { return 30 }
        if span <= HistoryTier.tenSeconds.retention { return 60 }
        return 180
    }

    /// Steps the time axis can use, in seconds: round minutes, hours and days.
    static let tickSteps: [TimeInterval] = [
        60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 2 * 86400, 5 * 86400, 7 * 86400
    ]

    /// Round times for the time axis: the smallest step giving at most `maxCount` ticks, aligned to
    /// the local clock. A tick within half a step of the right edge is left out, because its label
    /// wouldn't fit there and the chart would drop it, leaving a bare gridline.
    public static func ticks(in range: ClosedRange<Date>, maxCount: Int = 6, timeZone: TimeZone = .current) -> [Date] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return [] }
        let step = tickSteps.first { span / $0 <= Double(maxCount) } ?? tickSteps[tickSteps.count - 1]
        // Shifted into local time, so that hour and day ticks fall on the local clock's round values.
        let offset = TimeInterval(timeZone.secondsFromGMT(for: range.lowerBound))
        let localStart = range.lowerBound.timeIntervalSince1970 + offset
        var tick = (localStart / step).rounded(.up) * step - offset
        let last = range.upperBound.timeIntervalSince1970 - step / 2
        var result: [Date] = []
        while tick <= last {
            result.append(Date(timeIntervalSince1970: tick))
            tick += step
        }
        return result
    }

    /// Splits points wherever consecutive ones are further apart than `maxGap`, so that a line
    /// isn't drawn straight across a gap.
    public static func segments(_ points: [TimedValue], maxGap: TimeInterval) -> [[TimedValue]] {
        var result: [[TimedValue]] = []
        var current: [TimedValue] = []
        for point in points {
            if let last = current.last, point.time.timeIntervalSince(last.time) > maxGap {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Splits points, typically thinned ones, wherever a gap found in the full data falls between
    /// two of them. Thinned points can be far apart without any data missing between them.
    public static func segments(_ points: [TimedValue], breakingAt gaps: [ClosedRange<Date>]) -> [[TimedValue]] {
        guard !gaps.isEmpty else { return points.isEmpty ? [] : [points] }
        var result: [[TimedValue]] = []
        var current: [TimedValue] = []
        for point in points {
            if let last = current.last, gaps.contains(where: { $0.lowerBound >= last.time && $0.upperBound <= point.time }) {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Stretches with no data at all inside `range`: between points of any series further apart
    /// than `maxGap`, and before the first or after the last point.
    public static func gaps(
        in range: ClosedRange<Date>,
        times: [Date],
        maxGap: TimeInterval
    ) -> [ClosedRange<Date>] {
        let sorted = times.filter { range.contains($0) }.sorted()
        guard let first = sorted.first, let last = sorted.last else { return [range] }
        var result: [ClosedRange<Date>] = []
        if first.timeIntervalSince(range.lowerBound) > maxGap { result.append(range.lowerBound...first) }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.timeIntervalSince(earlier) > maxGap {
            result.append(earlier...later)
        }
        if range.upperBound.timeIntervalSince(last) > maxGap { result.append(last...range.upperBound) }
        return result
    }

    /// The value at or just before `time`, unless the nearest point is further than `maxGap` away,
    /// as in a gap.
    public static func value(at time: Date, in points: [TimedValue], maxGap: TimeInterval) -> TimedValue? {
        // Points are oldest first, so search from the end for the last one not after `time`.
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let point = points[low - 1]
        return time.timeIntervalSince(point.time) <= maxGap ? point : nil
    }
}
