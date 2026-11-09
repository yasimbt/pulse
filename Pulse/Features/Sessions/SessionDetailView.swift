import Charts
import PulseCore
import SwiftUI

/// One session: its name, summary, charts with throttle bands, and top processes.
struct SessionDetailView: View {
    let session: Session
    let model: SessionsModel
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    ForEach(SessionRows.rows) { row in
                        GridRow {
                            Text(row.id).foregroundStyle(.secondary)
                            Text(row.value(session.summary)).monospacedDigit()
                        }
                    }
                }
                ForEach(SessionChart.kinds, id: \.title) { kind in
                    SessionChart(kind: kind, session: session)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top processes").font(.headline)
                    ProcessList(processes: session.summary.topProcesses)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { name = session.name }
        .onChange(of: session.id) { name = session.name }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { model.rename(session.id, to: name) }
                Text(session.summary.start.formatted(date: .complete, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Export") {
                Button("JSON, everything") { model.export(session, as: .json) }
                Button("CSV, one row per second") { model.export(session, as: .csv) }
            }
            .fixedSize()
            Button("Delete", role: .destructive) { model.delete(session.id) }
        }
    }
}

/// One quantity over a session, with throttle periods shaded.
struct SessionChart: View {
    struct Kind: Sendable {
        let title: String
        let lines: [(name: String, value: @Sendable (SessionSample) -> Double?)]
        let format: @Sendable (Double) -> String
        let fixedDomain: ClosedRange<Double>?
    }

    static let kinds: [Kind] = [
        Kind(title: "Usage", lines: [("CPU", { $0.cpuUsage }), ("GPU", { $0.gpuUsage })], format: MetricFormat.percent, fixedDomain: 0...1),
        Kind(
            title: "Power",
            lines: [("CPU", { $0.cpuWatts }), ("GPU", { $0.gpuWatts }), ("Whole Mac", { $0.systemWatts })],
            format: MetricFormat.watts,
            fixedDomain: nil
        ),
        Kind(
            title: "Frequency",
            lines: [("Efficiency", { $0.efficiencyHz }), ("Performance", { $0.performanceHz })],
            format: MetricFormat.frequency,
            fixedDomain: nil
        ),
        Kind(title: "Chip temperature", lines: [("Hottest", { $0.chipCelsius })], format: MetricFormat.temperature, fixedDomain: nil)
    ]

    let kind: Kind
    let session: Session

    private struct Point: Identifiable {
        let id: Int
        let line: String
        let time: Date
        let value: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title).font(.headline)
                Spacer()
                if !session.summary.throttlePeriods.isEmpty {
                    Label("Throttled", systemImage: "square.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Chart {
                ForEach(session.summary.throttlePeriods, id: \.start) { period in
                    RectangleMark(xStart: .value("From", period.start), xEnd: .value("To", period.end.addingTimeInterval(1)))
                        .foregroundStyle(.orange.opacity(0.18))
                }
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value(kind.title, point.value), series: .value("Line", point.line))
                        .foregroundStyle(by: .value("Line", point.line))
                        .lineStyle(by: .value("Line", point.line))
                }
            }
            .chartXScale(domain: session.summary.start...max(session.summary.end, session.summary.start.addingTimeInterval(1)))
            .chartYScale(domain: kind.fixedDomain ?? 0...max(points.map(\.value).max() ?? 1, 1) * 1.1)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(kind.format(number)).frame(width: 72, alignment: .trailing) }
                    }
                }
            }
            .frame(height: 120)
            .padding(.trailing, 8)
            .accessibilityElement()
            .accessibilityLabel("\(kind.title) during the session")
        }
    }

    /// Thinned to 600 points per line, keeping peaks, so long sessions stay quick to draw.
    private var points: [Point] {
        var result: [Point] = []
        for line in kind.lines {
            let values = session.samples.compactMap { sample in line.value(sample).map { TimedValue(time: sample.time, value: $0) } }
            for value in MetricHistory.downsampled(values, maxCount: Timeline.maxPointsPerSeries) {
                result.append(Point(id: result.count, line: line.name, time: value.time, value: value.value))
            }
        }
        return result
    }
}
