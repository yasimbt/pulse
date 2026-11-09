import PulseCore
import SwiftUI

/// Recorded sessions: a list, one session's summary and charts, or two side by side.
struct SessionsView: View {
    @Bindable var model: SessionsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).lineLimit(1)
                        let started = session.summary.start.formatted(date: .abbreviated, time: .shortened)
                        Text("\(started) · \(MetricFormat.clock(session.summary.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .alert("Export failed", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        let selected = model.selected
        switch selected.count {
        case 1:
            SessionDetailView(session: selected[0], model: model)
        case 2:
            SessionCompareView(first: selected[0], second: selected[1])
        default:
            VStack(spacing: 8) {
                Text(model.sessions.isEmpty ? "No sessions yet" : "Select a session, or two to compare")
                    .font(.title3)
                Text("Record one with Record in any Pulse panel, or press \(HotKey.Shortcut.record.title) from anywhere.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The summary's rows, shared by the detail and the comparison so that they always match.
enum SessionRows {
    struct Row: Identifiable, Sendable {
        let id: String
        let value: @Sendable (SessionSummary) -> String
    }

    static let rows: [Row] = [
        Row(id: "Duration") { MetricFormat.clock($0.duration) },
        Row(id: "CPU usage, average / peak") { stat($0.cpuUsage, MetricFormat.percent) },
        Row(id: "GPU usage, average / peak") { stat($0.gpuUsage, MetricFormat.percent) },
        Row(id: "CPU power, average / peak") { stat($0.cpuWatts, MetricFormat.watts) },
        Row(id: "GPU power, average / peak") { stat($0.gpuWatts, MetricFormat.watts) },
        Row(id: "Whole Mac, average / peak") { stat($0.systemWatts, MetricFormat.watts) },
        Row(id: "Energy, CPU and GPU") { MetricFormat.energy(joules: $0.energyJoules) },
        Row(id: "Energy, whole Mac") { $0.systemEnergyJoules.map { MetricFormat.energy(joules: $0) } ?? "Not measured" },
        Row(id: "Hottest chip temperature") { $0.peakChipCelsius.map(MetricFormat.temperature) ?? "Not measured" },
        Row(id: "Thermal pressure, worst") { $0.worstThermalState.map { "\($0)".capitalized } ?? "Not measured" },
        Row(id: "Throttled") { throttled($0) }
    ]

    static func stat(_ value: Stat?, _ format: (Double) -> String) -> String {
        guard let value else { return "Not measured" }
        return "\(format(value.average)) / \(format(value.peak))"
    }

    static func throttled(_ summary: SessionSummary) -> String {
        guard summary.throttledSeconds > 0 else { return "No" }
        let share = summary.duration > 0 ? summary.throttledSeconds / summary.duration : 0
        return "\(MetricFormat.clock(summary.throttledSeconds)) (\(MetricFormat.percent(share)))"
    }
}

/// Two sessions side by side.
struct SessionCompareView: View {
    let first: Session
    let second: Session

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text(first.name).font(.headline)
                    Text(second.name).font(.headline)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(SessionRows.rows) { row in
                    GridRow {
                        Text(row.id).foregroundStyle(.secondary)
                        Text(row.value(first.summary)).monospacedDigit()
                        Text(row.value(second.summary)).monospacedDigit()
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .top) {
                    Text("Top processes").foregroundStyle(.secondary)
                    ProcessList(processes: first.summary.topProcesses)
                    ProcessList(processes: second.summary.topProcesses)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Processes by CPU time over a session.
struct ProcessList: View {
    let processes: [SessionProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if processes.isEmpty {
                Text("None recorded").foregroundStyle(.secondary)
            }
            ForEach(processes, id: \.pid) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    Spacer(minLength: 12)
                    Text("\(MetricFormat.clock(process.cpuSeconds)) CPU · \(MetricFormat.energy(joules: process.energyJoules))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}
