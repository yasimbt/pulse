import Charts
import PulseCore
import SwiftUI

/// The ten-minute chart in every panel.
struct HistoryChart: View {
    enum Scale { case fraction, rate }

    struct Line {
        let name: String
        let series: SeriesID
    }

    private struct Point: Identifiable {
        let line: String
        let time: Date
        let value: Double
        var id: String { "\(line)\(time.timeIntervalSince1970)" }
    }

    let title: String
    let lines: [Line]
    let scale: Scale
    let history: MetricHistory

    var body: some View {
        let now = Date()
        let points = lines.flatMap { line in
            history.points(line.series, now: now).map { Point(line: line.name, time: $0.time, value: $0.value) }
        }
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value(title, point.value),
                series: .value("Series", point.line)
            )
            .foregroundStyle(by: .value("Series", point.line))
            // Dashes keep the lines distinct without relying on colour.
            .lineStyle(by: .value("Series", point.line))
        }
        .chartXScale(domain: now.addingTimeInterval(-MetricHistory.window)...now)
        .chartYScale(domain: yDomain(points))
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(label(number)) }
                }
            }
        }
        .chartLegend(lines.count > 1 ? .visible : .hidden)
        .frame(height: 110)
        .accessibilityElement()
        .accessibilityLabel("\(title), last 10 minutes")
        .accessibilityValue(summary(points))
    }

    private func yDomain(_ points: [Point]) -> ClosedRange<Double> {
        switch scale {
        case .fraction: 0...1
        case .rate: 0...max(points.map(\.value).max() ?? 0, 1000) * 1.1
        }
    }

    private func label(_ value: Double) -> String {
        scale == .fraction ? MetricFormat.percent(value) : MetricFormat.compactRate(value)
    }

    private func summary(_ points: [Point]) -> String {
        lines.map { line in
            let values = points.filter { $0.line == line.name }.map(\.value)
            guard let latest = values.last, let peak = values.max() else { return "\(line.name): no data yet" }
            return "\(line.name): latest \(label(latest)), peak \(label(peak))"
        }
        .joined(separator: ". ")
    }
}
