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
