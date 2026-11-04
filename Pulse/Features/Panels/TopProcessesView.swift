import PulseCore
import SwiftUI

struct TopProcessesView: View {
    let kind: ModuleKind
    let snapshot: Snapshot?

    private struct Row: Identifiable {
        let id: Int32
        let name: String
        let value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if rows.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                MetricRow(row.name, row.value)
            }
            if kind != .network, let table = snapshot?.processes, table.unreadableCount > 0 {
                Text("\(table.unreadableCount) system processes aren't readable and aren't listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch kind {
        case .cpu, .battery: "Your top processes by CPU"
        case .memory: "Your top processes by memory"
        case .disk: "Your top processes by disk"
        case .network: "Top processes by network"
        }
    }

    private var rows: [Row] {
        switch kind {
        case .cpu, .battery:
            return (snapshot?.processes?.byCPU ?? []).map {
                Row(id: $0.pid, name: $0.name, value: MetricFormat.cores($0.cpuCores))
            }
        case .memory:
            return (snapshot?.processes?.byMemory ?? []).map {
                Row(id: $0.pid, name: $0.name, value: MetricFormat.memory(Double($0.footprintBytes)))
            }
        case .disk:
            return (snapshot?.processes?.byDisk ?? []).map {
                Row(id: $0.pid, name: $0.name, value: MetricFormat.rate($0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond))
            }
        case .network:
            return (snapshot?.networkProcesses ?? []).map {
                let down = MetricFormat.rate($0.downBytesPerSecond)
                let upload = MetricFormat.rate($0.upBytesPerSecond)
                return Row(id: $0.pid, name: $0.name, value: "↓\(down) ↑\(upload)")
            }
        }
    }
}
