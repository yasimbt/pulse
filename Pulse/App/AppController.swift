import AppKit
import PulseCore
import SwiftUI

/// Connects the sampler, model, settings, and status items.
@MainActor
final class AppController: NSObject, NSWindowDelegate {
    private let store = SettingsStore()
    private let model = LiveModel()
    private let sampler: Sampler
    private let statusBar: StatusBarController
    private var openPanel: Set<ModuleKind>?
    private var settingsWindow: NSWindow?
    private var consumer: Task<Void, Never>?

    override init() {
        let settings = store.settings
        sampler = Sampler(
            interval: settings.sampleInterval,
            demand: Sampler.Demand(modules: Set(settings.enabledModules.map(\.kind)))
        )
        statusBar = StatusBarController(model: model)
        super.init()
    }

    func start() {
        statusBar.actions = PanelActions(
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApplication.shared.terminate(nil) },
            openActivityMonitor: {
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        )
        statusBar.onPanelChange = { [weak self] kinds in
            self?.openPanel = kinds
            self?.updateDemand()
        }
        store.onChange = { [weak self] settings in self?.apply(settings) }
        statusBar.apply(store.settings)

        let sampler = sampler
        consumer = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.snapshots {
                guard let self else { return }
                model.ingest(snapshot, enabled: store.settings.enabledModules.map(\.kind))
                statusBar.update(with: store.settings)
            }
        }
    }

    private func apply(_ settings: PulseSettings) {
        statusBar.apply(settings)
        statusBar.update(with: settings)
        updateDemand()
        let sampler = sampler
        Task { await sampler.setInterval(settings.sampleInterval) }
    }

    /// Process scans and `nettop` run only while a panel that shows them is open.
    private func updateDemand() {
        let demand = Sampler.Demand(
            modules: Set(store.settings.enabledModules.map(\.kind)),
            processes: openPanel != nil,
            networkProcesses: openPanel?.contains(.network) ?? false
        )
        let sampler = sampler
        Task { await sampler.setDemand(demand) }
    }

    private func showSettings() {
        statusBar.closePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, model: model)))
            window.title = "\(PulseInfo.appName) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // A menu-bar app has no Dock icon, so it must bring itself forward explicitly.
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Dropping the window also stops its views from redrawing every sample.
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}
