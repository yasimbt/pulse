import PulseCore
import SwiftUI

struct ModulePanel: View {
    let kind: ModuleKind
    let model: LiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.headline)
            details
            chart
            TopProcessesView(kind: kind, snapshot: model.snapshot)
        }
    }

    @ViewBuilder private var details: some View {
        switch kind {
        case .cpu: CPUDetails(sample: model.snapshot?.cpu)
        case .memory: MemoryDetails(sample: model.snapshot?.memory)
        case .disk: DiskDetails(sample: model.snapshot?.disk)
        case .network: NetworkDetails(sample: model.snapshot?.network)
        case .battery: BatteryDetails(sample: model.snapshot?.battery)
        case .power: PowerDetails(
                sample: model.snapshot?.power, thermal: model.snapshot?.thermal, smc: model.snapshot?.smc, energyJoules: model.energyJoules
            )
        }
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .cpu:
            HistoryChart(title: "CPU", lines: [.init(name: "Used", series: .cpuTotal)], scale: .fraction, history: model.history)
        case .memory:
            HistoryChart(title: "Memory", lines: [.init(name: "Used", series: .memoryUsed)], scale: .fraction, history: model.history)
        case .disk:
            HistoryChart(
                title: "Disk",
                lines: [.init(name: "Read", series: .diskRead), .init(name: "Write", series: .diskWrite)],
                scale: .rate,
                history: model.history
            )
        case .network:
            HistoryChart(
                title: "Network",
                lines: [.init(name: "Down", series: .networkDown), .init(name: "Up", series: .networkUp)],
                scale: .rate,
                history: model.history
            )
        case .battery:
            HistoryChart(title: "Battery", lines: [.init(name: "Charge", series: .batteryCharge)], scale: .fraction, history: model.history)
        case .power:
            HistoryChart(
                title: "Power",
                lines: [.init(name: "CPU", series: .powerCPU), .init(name: "GPU", series: .powerGPU)],
                scale: .watts,
                history: model.history,
                stacked: true
            )
        }
    }
}

/// One label and value, read as a single sentence by VoiceOver.
struct MetricRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct CPUDetails: View {
    let sample: CPUSample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                MetricRow("Total", MetricFormat.precisePercent(sample.total))
                MetricRow("User", MetricFormat.precisePercent(sample.user))
                MetricRow("System", MetricFormat.precisePercent(sample.system))
                ForEach(sample.clusters, id: \.name) { cluster in
                    MetricRow("\(cluster.name) (\(cluster.coreCount) cores)", MetricFormat.precisePercent(cluster.usage))
                }
                CoreBars(cores: sample.cores)
            }
        }
    }
}

/// One small bar per core, grouped left to right in core order.
struct CoreBars: View {
    let cores: [CoreLoad]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(cores, id: \.index) { core in
                GeometryReader { proxy in
                    VStack {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.tint)
                            .frame(height: proxy.size.height * core.usage)
                    }
                }
                .background(.quaternary)
                .accessibilityElement()
                .accessibilityLabel("Core \(core.index), \(core.clusterName)")
                .accessibilityValue(MetricFormat.precisePercent(core.usage))
            }
        }
        .frame(height: 28)
    }
}

struct MemoryDetails: View {
    let sample: MemorySample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                let total = MetricFormat.memory(Double(sample.totalBytes))
                MetricRow("Used", "\(MetricFormat.memory(Double(sample.usedBytes))) of \(total)")
                MetricRow("App", MetricFormat.memory(Double(sample.appBytes)))
                MetricRow("Wired", MetricFormat.memory(Double(sample.wiredBytes)))
                MetricRow("Compressed", MetricFormat.memory(Double(sample.compressedBytes)))
                MetricRow("Swap used", MetricFormat.memory(Double(sample.swapUsedBytes)))
                if let pressure = sample.pressure {
                    MetricRow("Pressure", pressureName(pressure))
                }
            }
        }
    }

    private func pressureName(_ pressure: MemorySample.Pressure) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

struct DiskDetails: View {
    let sample: DiskSample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                MetricRow("Available", "\(MetricFormat.bytes(Double(sample.availableBytes))) of \(MetricFormat.bytes(Double(sample.totalBytes)))")
                MetricRow("Read", MetricFormat.rate(sample.readBytesPerSecond))
                MetricRow("Write", MetricFormat.rate(sample.writeBytesPerSecond))
            }
        }
    }
}

struct NetworkDetails: View {
    let sample: NetworkSample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                MetricRow("Down", MetricFormat.rate(sample.downBytesPerSecond))
                MetricRow("Up", MetricFormat.rate(sample.upBytesPerSecond))
                ForEach(sample.interfaces, id: \.name) { interface in
                    let down = MetricFormat.rate(interface.downBytesPerSecond)
                    let upload = MetricFormat.rate(interface.upBytesPerSecond)
                    MetricRow(interface.name, "↓\(down) ↑\(upload)")
                }
            }
        }
    }
}

struct BatteryDetails: View {
    let sample: BatterySample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                MetricRow("Charge", MetricFormat.percent(sample.chargeFraction))
                MetricRow("State", state(sample))
                if let time = sample.timeRemainingSeconds { MetricRow("Time remaining", MetricFormat.duration(time)) }
                if let power = sample.powerWatts { MetricRow("Power", String(format: "%.1f W", power)) }
                if let voltage = sample.voltageVolts { MetricRow("Voltage", String(format: "%.2f V", voltage)) }
                if let health = sample.healthFraction { MetricRow("Capacity vs. design", MetricFormat.percent(health)) }
                if let cycles = sample.cycleCount { MetricRow("Cycles", "\(cycles)") }
                if let temperature = sample.temperatureCelsius { MetricRow("Temperature", String(format: "%.1f °C", temperature)) }
            }
        }
    }

    private func state(_ sample: BatterySample) -> String {
        if sample.isFullyCharged { return "Fully charged" }
        if sample.isCharging { return "Charging" }
        return sample.isExternalPowerConnected ? "On power adapter, not charging" : "On battery"
    }
}
