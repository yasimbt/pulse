import Charts
import PulseCore
import SwiftUI

/// The history window: every recorded metric on one time axis, with zoom, a scrubber and a
/// crosshair that shows each value, and the busiest processes, at the selected time.
struct HistoryView: View {
    @Bindable var model: HistoryModel

    private static let spanTitles: [(TimeInterval, String)] = [(3600, "1 h"), (21600, "6 h"), (86400, "24 h"), (604_800, "7 d"), (2_592_000, "30 d")]

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(12)
            Divider()
            HStack(spacing: 0) {
                charts
                Divider()
                ReadoutView(model: model).frame(width: 260)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $model.span) {
                ForEach(Self.spanTitles, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.spanTitles.contains(where: { $0.0 == model.span }) {
                    Text(MetricFormat.duration(model.span)).tag(model.span)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            // The scrubber: drag through the last 30 days. Right is now.
            Slider(value: Binding(get: { -model.offset }, set: { model.offset = -$0 }), in: -(30 * 86400 - model.span)...0)
                .accessibilityLabel("Time")
                .accessibilityValue(model.offset == 0 ? "Now" : "\(MetricFormat.duration(model.offset)) ago")
            Button("Now") { model.offset = 0 }
                .disabled(model.offset == 0)
            if let milliseconds = model.lastLoadMilliseconds {
                Text("\(Int(milliseconds)) ms").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Time to read and prepare this range")
            }
        }
    }

    private var charts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.visibleGroups.isEmpty {
                    Text(model.isLoading ? "Loading…" : "No history in this range yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(model.visibleGroups) { group in
                    TimelineChart(group: group, model: model)
                }
            }
            .padding(12)
        }
        // Pinch on the trackpad to zoom.
        .gesture(MagnifyGesture().onEnded { model.zoom(by: $0.magnification) })
    }
}

/// One group's chart, sharing the range, gaps and crosshair with the others.
struct TimelineChart: View {
    let group: HistoryModel.Group
    @Bindable var model: HistoryModel

    private struct Point: Identifiable {
        let id: Int
        let line: String
        let segment: String
        let time: Date
        let value: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.id).font(.headline)
            Chart {
                ForEach(model.gaps, id: \.lowerBound) { gap in
                    RectangleMark(xStart: .value("From", gap.lowerBound), xEnd: .value("To", gap.upperBound))
                        .foregroundStyle(.gray.opacity(0.15))
                }
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value(group.id, point.value), series: .value("Segment", point.segment))
                        .foregroundStyle(by: .value("Series", point.line))
                        .lineStyle(by: .value("Series", point.line))
                }
                if let selection = model.selection {
                    RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: model.range)
            .chartXAxis {
                // Round times chosen by Pulse, none so close to the right edge that its label is dropped.
                AxisMarks(values: Timeline.ticks(in: model.range)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: timeFormat)
                }
            }
            .chartYScale(domain: yDomain)
            .chartXSelection(value: $model.selection)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    // A fixed width keeps every chart's time axis lined up, whatever its units.
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(format(number)).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            .chartLegend(group.lines.count > 1 ? .visible : .hidden)
            .frame(height: 110)
            .padding(.trailing, 8)
            .accessibilityElement()
            .accessibilityLabel("\(group.id) history")
        }
    }

    /// Hours and minutes up to a day; dates beyond, where the time of day means little.
    private var timeFormat: Date.FormatStyle {
        model.span > 86400 ? .dateTime.day().month(.abbreviated) : .dateTime.hour().minute()
    }

    /// Each line is split where its full data has a gap, so that it isn't drawn across time with no
    /// data. Splitting by the spacing of the thinned points would break lines that have no gap.
    private var points: [Point] {
        var result: [Point] = []
        for line in group.lines {
            let segments = Timeline.segments(model.drawn[line.series] ?? [], breakingAt: model.seriesGaps[line.series] ?? [])
            for (index, segment) in segments.enumerated() {
                for value in segment {
                    result.append(Point(id: result.count, line: line.name, segment: "\(line.name) \(index)", time: value.time, value: value.value))
                }
            }
        }
        return result
    }

    private var yDomain: ClosedRange<Double> {
        let peak = group.lines.flatMap { model.drawn[$0.series] ?? [] }.map(\.value).max() ?? 0
        switch group.scale {
        case .fraction: return 0...1
        case .rate: return 0...max(peak, 1000) * 1.1
        case .watts: return 0...max(peak, 1) * 1.1
        }
    }

    func format(_ value: Double) -> String {
        HistoryFormat.value(value, group.scale)
    }
}

enum HistoryFormat {
    static func value(_ value: Double, _ scale: HistoryScale) -> String {
        switch scale {
        case .fraction: MetricFormat.percent(value)
        case .rate: MetricFormat.rate(value)
        case .watts: MetricFormat.watts(value)
        }
    }
}

/// Every value, and the busiest processes, at the crosshair.
struct ReadoutView: View {
    let model: HistoryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let time = model.selection {
                    Text(time.formatted(date: .abbreviated, time: .standard)).font(.headline)
                    ForEach(model.visibleGroups) { group in
                        ForEach(group.lines, id: \.series) { line in
                            let title = group.lines.count > 1 ? "\(group.id) \(line.name.lowercased())" : group.id
                            MetricRow(title, model.value(of: line.series, at: time).map { HistoryFormat.value($0, group.scale) } ?? "No data")
                        }
                    }
                    Text("Busiest processes").font(.subheadline.weight(.semibold)).padding(.top, 8)
                    if model.processes.isEmpty {
                        Text("No snapshot near this time.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.processes, id: \.pid) { process in
                        MetricRow(process.name, MetricFormat.cores(process.cpuCores))
                    }
                } else {
                    Text("Click a chart to see every value at that moment.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
