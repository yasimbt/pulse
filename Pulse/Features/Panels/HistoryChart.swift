import Charts
import PulseCore
import SwiftUI

/// The ten-minute chart in every panel.
struct HistoryChart: View {
    enum Scale { case fraction, rate, watts }

    struct Line {
        let name: String
        let series: SeriesID
    }

    private struct Point: Identifiable {
        let id: Int
        let line: String
        let time: Date
        let value: Double
    }

    /// The chart is about 330 pt wide, so more points add cost but no visible detail.
    private static let maxPointsPerLine = 120

    let title: String
    let lines: [Line]
    let scale: Scale
    let history: MetricHistory
    /// Stacks the lines as filled areas, so the top edge is their total.
    var stacked = false

    var body: some View {
        let now = Date()
        let points = chartPoints(now: now)
        Chart(points) { point in
            if stacked {
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value(title, point.value),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Series", point.line))
            } else {
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(title, point.value),
                    series: .value("Series", point.line)
                )
                .foregroundStyle(by: .value("Series", point.line))
                // Dashes keep the lines distinct without relying on colour.
                .lineStyle(by: .value("Series", point.line))
            }
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

    private func chartPoints(now: Date) -> [Point] {
        var points: [Point] = []
        for line in lines {
            let all = history.points(line.series, now: now)
            // Stacking needs the same times in every line, which bucket peaks don't keep.
            let reduced = stacked
                ? Self.strided(all, maxCount: Self.maxPointsPerLine)
                : MetricHistory.downsampled(all, maxCount: Self.maxPointsPerLine)
            for value in reduced {
                points.append(Point(id: points.count, line: line.name, time: value.time, value: value.value))
            }
        }
        return points
    }

    private static func strided(_ points: [TimedValue], maxCount: Int) -> [TimedValue] {
        guard points.count > maxCount else { return points }
        let step = Int((Double(points.count) / Double(maxCount)).rounded(.up))
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    private func yDomain(_ points: [Point]) -> ClosedRange<Double> {
        let peak: Double
        if stacked {
            // The top of a stack is the sum at each time.
            peak = Dictionary(grouping: points, by: \.time).values.map { $0.reduce(0) { $0 + $1.value } }.max() ?? 0
        } else {
            peak = points.map(\.value).max() ?? 0
        }
        switch scale {
        case .fraction: return 0...1
        case .rate: return 0...max(peak, 1000) * 1.1
        case .watts: return 0...max(peak, 1) * 1.1
        }
    }

    private func label(_ value: Double) -> String {
        switch scale {
        case .fraction: MetricFormat.percent(value)
        case .rate: MetricFormat.compactRate(value)
        case .watts: MetricFormat.watts(value)
        }
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
