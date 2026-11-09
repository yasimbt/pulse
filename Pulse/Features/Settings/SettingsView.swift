import PulseCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: SettingsStore
    let model: LiveModel

    /// Edits one rule, creating the rule settings on first use.
    private func ruleBinding(_ path: WritableKeyPath<RuleSettings, RuleActions>) -> Binding<RuleActions> {
        Binding(
            get: { (store.settings.rules ?? .default)[keyPath: path] },
            set: { actions in
                var rules = store.settings.rules ?? .default
                rules[keyPath: path] = actions
                store.settings.rules = rules
            }
        )
    }

    var body: some View {
        Form {
            Section("Modules") {
                ForEach(store.settings.modules.indices, id: \.self) { index in
                    ModuleRow(
                        config: $store.settings.modules[index],
                        isAvailable: !model.unavailableModules.contains(store.settings.modules[index].kind),
                        moveUp: index > 0 ? { store.settings.modules.swapAt(index, index - 1) } : nil,
                        moveDown: index < store.settings.modules.count - 1 ? { store.settings.modules.swapAt(index, index + 1) } : nil
                    )
                }
                Toggle("Show all modules in one menu-bar item", isOn: $store.settings.isCombined)
            }
            Section("General") {
                Picker("Sample rate", selection: $store.settings.sampleInterval) {
                    ForEach(PulseSettings.sampleIntervals, id: \.self) { interval in
                        Text(interval == 1 ? "1 second" : "\(interval.formatted()) seconds").tag(interval)
                    }
                }
                LaunchAtLoginToggle()
            }
            Section("Rules") {
                RuleRow(title: "On battery", actions: ruleBinding(\.onBattery))
                RuleRow(title: "In Low Power Mode", actions: ruleBinding(\.lowPowerMode))
                Text("While a rule applies, its sample rate and hidden modules replace yours. The slower rate wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Alerts") {
                AlertRows(alerts: Binding(
                    get: { store.settings.alerts ?? .default },
                    set: { store.settings.alerts = $0 }
                ))
            }
            Section("Heads-up display") {
                HUDRows(hud: Binding(get: { store.settings.hud ?? .default }, set: { store.settings.hud = $0 }))
            }
            Section("Sharing") {
                MetricsServerRows(port: $store.settings.metricsServerPort)
            }
            Section("Pulse's own overhead") {
                OverheadRows(model: model)
            }
        }
        .formStyle(.grouped)
        // A fixed height that fits a laptop screen; the grouped form scrolls inside it.
        .frame(width: 520, height: 640)
    }
}

/// One rule: a slower sample rate and modules to hide while its condition holds.
private struct RuleRow: View {
    let title: String
    @Binding var actions: RuleActions

    var body: some View {
        LabeledContent(title) {
            HStack {
                Picker("Sample rate", selection: $actions.sampleInterval) {
                    Text("Usual rate").tag(Double?.none)
                    Text("Every 2 seconds").tag(Double?.some(2))
                    Text("Every 5 seconds").tag(Double?.some(5))
                }
                .labelsHidden()
                .fixedSize()
                Menu(hiddenTitle) {
                    ForEach(ModuleKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { actions.hiddenModules.contains(kind) },
                            set: { hide in
                                if hide { actions.hiddenModules.insert(kind) } else { actions.hiddenModules.remove(kind) }
                            }
                        ))
                    }
                }
                .fixedSize()
            }
        }
    }

    private var hiddenTitle: String {
        actions.hiddenModules.isEmpty ? "Hide nothing" : "Hide \(actions.hiddenModules.count)"
    }
}

/// A switch per alert, with thresholds for the ones that have one.
private struct AlertRows: View {
    @Binding var alerts: AlertSettings

    var body: some View {
        ForEach(AlertKind.allCases, id: \.self) { kind in
            Toggle(isOn: Binding(
                get: { alerts.enabled.contains(kind) },
                set: { isOn in
                    if isOn { alerts.enabled.insert(kind) } else { alerts.enabled.remove(kind) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(detail(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if alerts.enabled.contains(.chipTemperature) {
            Stepper("Chip temperature: \(Int(alerts.chipCelsius)) °C", value: $alerts.chipCelsius, in: 70...110, step: 5)
        }
        if alerts.enabled.contains(.lowDiskSpace) {
            Stepper("Free space under \(Int(alerts.minimumFreeBytes / 1e9)) GB", value: $alerts.minimumFreeBytes, in: 5e9...200e9, step: 5e9)
        }
        Text("Checked every 10 seconds. Each alert waits a while before repeating.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func detail(_ kind: AlertKind) -> String {
        switch kind {
        case .chipTemperature: "When the chip stays at \(Int(alerts.chipCelsius)) °C or more for a minute"
        case .swapGrowth: "When swap grows by \(MetricFormat.memory(alerts.swapGrowthBytes)) in 10 minutes"
        case .lowDiskSpace: "When the startup disk has under \(Int(alerts.minimumFreeBytes / 1e9)) GB or 5% free"
        case .batteryHealth: "When the battery holds under \(MetricFormat.percent(alerts.minimumBatteryHealth)) of its design capacity"
        case .thermalPressure: "When macOS reports thermal pressure for minutes at a time"
        case .chargerShortfall: "When the battery drains although a charger is connected"
        }
    }
}

/// The floating HUD's switch and corner.
private struct HUDRows: View {
    @Binding var hud: HUDSettings

    var body: some View {
        Toggle("Show a floating HUD (\(HotKey.Shortcut.hud.title))", isOn: $hud.isVisible)
        Picker("Corner", selection: $hud.corner) {
            ForEach(HUDSettings.Corner.allCases) { Text($0.title).tag($0) }
        }
        Text("Stays above other windows, including full-screen apps, and lets clicks pass through. "
            + "While it shows, Pulse reads power and temperature every second (about 1-2% CPU).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The opt-in localhost endpoint for Prometheus and scripts.
private struct MetricsServerRows: View {
    @Binding var port: Int?

    var body: some View {
        Toggle("Serve metrics on this Mac (localhost only)", isOn: Binding(
            get: { port != nil },
            set: { port = $0 ? Int(MetricsServer.defaultPort) : nil }
        ))
        if let current = port {
            TextField("Port", value: Binding(get: { current }, set: { port = $0 }), format: .number.grouping(.never))
            Text("Prometheus: http://127.0.0.1:\(String(current))/metrics · JSON: /metrics.json. "
                + "Only programs on this Mac can connect, and it covers the modules shown in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Its own view, so that only these rows redraw on each sample.
private struct OverheadRows: View {
    let model: LiveModel

    var body: some View {
        if let usage = model.selfUsage {
            MetricRow("CPU now", MetricFormat.cores(usage.cpuCores))
            MetricRow("CPU average since launch", String(format: "%.2f%%", usage.averageCPUCores * 100))
            MetricRow("Memory", MetricFormat.memory(Double(usage.footprintBytes)))
        }
    }
}

private struct ModuleRow: View {
    @Binding var config: ModuleConfig
    let isAvailable: Bool
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    var body: some View {
        HStack {
            Toggle(config.kind.title, isOn: $config.isEnabled)
                .frame(width: 100, alignment: .leading)
            if !isAvailable {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("\(config.kind.title) style", selection: $config.renderer) {
                ForEach(RendererKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            Picker("\(config.kind.title) colour", selection: $config.tint) {
                ForEach(ModuleTint.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            Button { moveUp?() } label: { Image(systemName: "chevron.up") }
                .disabled(moveUp == nil)
                .accessibilityLabel("Move \(config.kind.title) left in the menu bar")
            Button { moveDown?() } label: { Image(systemName: "chevron.down") }
                .disabled(moveDown == nil)
                .accessibilityLabel("Move \(config.kind.title) right in the menu bar")
        }
    }
}

/// `SMAppService.mainApp` registers this app bundle to start when the user logs in.
private struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { isOn }, set: change))
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func change(_ newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        isOn = SMAppService.mainApp.status == .enabled
    }
}
