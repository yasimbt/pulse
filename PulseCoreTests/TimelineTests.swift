import Foundation
@testable import PulseCore
import Testing

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func points(_ seconds: [Int]) -> [TimedValue] {
    seconds.map { TimedValue(time: start.addingTimeInterval(TimeInterval($0)), value: Double($0)) }
}

@Test func linesBreakAtGaps() {
    let segments = Timeline.segments(points([0, 1, 2, 100, 101, 400]), maxGap: 30)
    #expect(segments.map { $0.map(\.value) } == [[0, 1, 2], [100, 101], [400]])
    #expect(Timeline.segments([], maxGap: 30).isEmpty)
}

@Test func thinnedLinesBreakOnlyAtRealGaps() {
    // Thinned points 144 s apart with one real gap between 300 and 700 s.
    let thinned = points([0, 144, 288, 720, 864])
    let gap = start.addingTimeInterval(300)...start.addingTimeInterval(700)
    let segments = Timeline.segments(thinned, breakingAt: [gap])
    #expect(segments.map { $0.map(\.value) } == [[0, 144, 288], [720, 864]])
    #expect(Timeline.segments(thinned, breakingAt: []).count == 1)
}

@Test func gapsIncludeTheEdgesOfTheRange() {
    let range = start...start.addingTimeInterval(1000)
    let times = points([100, 110, 500, 510]).map(\.time)
    let gaps = Timeline.gaps(in: range, times: times, maxGap: 30)
    let seconds = gaps.map { [$0.lowerBound.timeIntervalSince(start), $0.upperBound.timeIntervalSince(start)] }
    #expect(seconds == [[0, 100], [110, 500], [510, 1000]])
    // A range with no data at all is one gap.
    #expect(Timeline.gaps(in: range, times: [], maxGap: 30) == [range])
}

@Test func valueAtATimeIsTheLastPointBeforeIt() {
    let series = points([0, 10, 20, 200])
    #expect(Timeline.value(at: start.addingTimeInterval(15), in: series, maxGap: 30)?.value == 10)
    #expect(Timeline.value(at: start.addingTimeInterval(20), in: series, maxGap: 30)?.value == 20)
    // Before the first point, or inside a gap, there is no value.
    #expect(Timeline.value(at: start.addingTimeInterval(-1), in: series, maxGap: 30) == nil)
    #expect(Timeline.value(at: start.addingTimeInterval(100), in: series, maxGap: 30) == nil)
}

@Test func gapThresholdFollowsTheTierARangeIsReadFrom() {
    #expect(Timeline.gapThreshold(forSpan: 3600) == 30)
    #expect(Timeline.gapThreshold(forSpan: 86400) == 60)
    #expect(Timeline.gapThreshold(forSpan: 7 * 86400) == 180)
}

@Test func axisTicksAreRoundTimesAwayFromTheRightEdge() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    // 1 h ending at 22:05:20 UTC: 10 min steps, the smallest giving at most six ticks. 22:00 is more
    // than half a step from the edge, so it stays.
    let end = Date(timeIntervalSince1970: 1_800_000_000 + 22 * 3600 + 320)
    let ticks = Timeline.ticks(in: end.addingTimeInterval(-3600)...end, timeZone: utc)
    let minutes = ticks.map { Int($0.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)) / 60 }
    #expect(minutes == [10, 20, 30, 40, 50, 0])
    // Ending at 22:02, a 22:00 tick would sit 2 minutes from the edge and lose its label, so it's left out.
    let close = Date(timeIntervalSince1970: 1_800_000_000 + 22 * 3600 + 120)
    let closeMinutes = Timeline.ticks(in: close.addingTimeInterval(-3600)...close, timeZone: utc)
        .map { Int($0.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)) / 60 }
    #expect(closeMinutes == [10, 20, 30, 40, 50])
    // 30 days: 5-day steps, at most six of them.
    let month = Timeline.ticks(in: end.addingTimeInterval(-30 * 86400)...end, timeZone: utc)
    #expect(month.count <= 6 && month.count >= 5)
    #expect(zip(month, month.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 5 * 86400 })
}
