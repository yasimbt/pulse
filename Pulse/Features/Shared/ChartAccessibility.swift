import Accessibility
import Foundation
import PulseCore
import SwiftUI

/// Describes a time chart to VoiceOver's audio graphs, which play a chart as rising and falling
/// tones and let a person step through its points. Shared by the panel, history and session charts.
struct TimeChartDescriptor: AXChartDescriptorRepresentable {
    struct Line {
        let name: String
        let points: [TimedValue]
    }

    let title: String
    let lines: [Line]
    let range: ClosedRange<Date>
    let valueRange: ClosedRange<Double>
    let format: @Sendable (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = range.lowerBound.timeIntervalSince1970
        let end = max(range.upperBound.timeIntervalSince1970, start + 1)
        let xAxis = AXNumericDataAxisDescriptor(title: "Time", range: start...end, gridlinePositions: []) { seconds in
            Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
        }
        let yAxis = AXNumericDataAxisDescriptor(title: title, range: valueRange, gridlinePositions: [], valueDescriptionProvider: format)
        let series = lines.map { line in
            AXDataSeriesDescriptor(
                name: line.name,
                isContinuous: true,
                dataPoints: line.points.map { AXDataPoint(x: $0.time.timeIntervalSince1970, y: $0.value) }
            )
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series)
    }

    /// Spoken before the audio graph: each line's latest value and peak.
    var summary: String {
        lines.map { line in
            guard let latest = line.points.last?.value, let peak = line.points.map(\.value).max() else {
                return "\(line.name): no data"
            }
            return "\(line.name): latest \(format(latest)), peak \(format(peak))"
        }
        .joined(separator: ". ")
    }
}
