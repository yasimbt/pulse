import AppKit
import os
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
    private var historyWindow: NSWindow?
    private var sessionsWindow: NSWindow?
    private var sessionsModel: SessionsModel?
    private var consumer: Task<Void, Never>?
    private var hotKey: HotKey?
    /// Nil when the database can't be opened, in which case Pulse runs without history or sessions.
    private let database: HistoryDatabase?
    private let history: HistoryStore?
    private let recorder: SessionRecorder?
    private let metricsServer = MetricsServer()
    private let alerts = AlertNotifier()
    /// On battery or in Low Power Mode, rules can change the settings that run.
    private var powerContext = PowerContext.current()
    private var lastPowerCheck = Date()
    private var powerStateObserver: NSObjectProtocol?

    /// The person's settings, changed by any rule that applies now. Settings shows their own.
    private var effective: PulseSettings { Rules.effective(store.settings, context: powerContext) }
    private var metricsServerPort: Int?

    override init() {
        let settings = Rules.effective(store.settings, context: PowerContext.current())
        sampler = Sampler(
            interval: settings.sampleInterval,
            demand: Sampler.Demand(modules: Set(settings.enabledModules.map(\.kind)))
        )
        statusBar = StatusBarController(model: model)
        do {
            database = try HistoryDatabase.open(at: HistoryStore.defaultURL)
        } catch {
            Logger(subsystem: PulseInfo.logSubsystem, category: "history")
                .error("history unavailable: \(String(describing: error), privacy: .public)")
            database = nil
        }
        history = database.map(HistoryStore.init)
        recorder = database.map(SessionRecorder.init)
        super.init()
    }

    func start() {
        statusBar.actions = PanelActions(
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApplication.shared.terminate(nil) },
            openActivityMonitor: {
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            },
            openHistory: history == nil ? nil : { [weak self] in self?.showHistory() },
            toggleRecording: recorder == nil ? nil : { [weak self] in self?.toggleRecording() },
            openSessions: database == nil ? nil : { [weak self] in self?.showSessions() }
        )
        if recorder != nil {
            hotKey = HotKey { [weak self] in self?.toggleRecording() }
        }
        statusBar.onPanelChange = { [weak self] kinds in
            self?.openPanel = kinds
            self?.updateDemand()
        }
        store.onChange = { [weak self] _ in self?.applyEffective() }
        IntentBridge.controller = self
        statusBar.apply(effective)
        applyMetricsServer(store.settings)
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPowerContext() }
        }
        // Sends the full demand, including the process scans that history needs.
        updateDemand()

        let sampler = sampler
        consumer = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.snapshots {
                guard let self else { return }
                if snapshot.timestamp.timeIntervalSince(lastPowerCheck) >= 10 { checkPowerContext() }
                let settings = effective
                model.ingest(snapshot, enabled: settings.enabledModules.map(\.kind))
                statusBar.update(with: settings)
                await history?.record(snapshot)
                await recorder?.record(snapshot)
                if metricsServerPort != nil { await metricsServer.update(snapshot) }
                alerts.check(snapshot, settings: store.settings.alerts ?? .default)
            }
        }
    }

    /// Writes buffered history, so that quitting loses nothing.
    func flushHistory() async {
        await history?.flush()
    }

    /// Starts, moves or stops the localhost endpoint to match settings.
    private func applyMetricsServer(_ settings: PulseSettings) {
        guard settings.metricsServerPort != metricsServerPort else { return }
        metricsServerPort = settings.metricsServerPort
        let server = metricsServer
        let port = settings.metricsServerPort
        Task {
            if let port {
                do {
                    try await server.start(port: UInt16(port))
                } catch {
                    Logger(subsystem: PulseInfo.logSubsystem, category: "server")
                        .error("metrics server couldn't start: \(String(describing: error), privacy: .public)")
                }
            } else {
                await server.stop()
            }
        }
    }

    /// Re-applies settings when the power situation changes a rule's outcome.
    private func checkPowerContext() {
        lastPowerCheck = Date()
        let context = PowerContext.current()
        guard context != powerContext else { return }
        powerContext = context
        applyEffective()
    }

    private func applyEffective() {
        apply(effective)
    }

    private func apply(_ settings: PulseSettings) {
        applyMetricsServer(settings)
        alerts.settingsChanged(settings.alerts ?? .default)
        statusBar.apply(settings)
        statusBar.update(with: settings)
        updateDemand()
        let sampler = sampler
        Task { await sampler.setInterval(settings.sampleInterval) }
    }

    /// Process scans run only while a panel is open, and `nettop` only while Network is showing.
    private func updateDemand() {
        let demand = Sampler.Demand(
            modules: Set(effective.enabledModules.map(\.kind)),
            processes: openPanel != nil || model.recordingStart != nil,
            networkProcesses: openPanel?.contains(.network) ?? false,
            // A session needs frequencies, temperatures and processes every second.
            powerDetail: (openPanel?.contains(.power) ?? false) || model.recordingStart != nil,
            portsDetail: openPanel?.contains(.ports) ?? false,
            alerts: !(store.settings.alerts ?? .default).enabled.isEmpty,
            processHistory: history != nil
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

    private func showHistory() {
        statusBar.closePanel()
        guard let history else { return }
        if historyWindow == nil {
            let view = HistoryView(model: HistoryModel(store: history))
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "\(PulseInfo.appName) History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 960, height: 720))
            window.center()
            historyWindow = window
        }
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    /// Dropping a window also frees its views and, for history, its loaded data.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { settingsWindow = nil }
        if window === historyWindow { historyWindow = nil }
        if window === sessionsWindow {
            sessionsWindow = nil
            sessionsModel = nil
        }
    }
}

// MARK: - Sessions

extension AppController {
    /// Starts a session, or stops the current one and shows its summary.
    func toggleRecording() {
        Task {
            if model.recordingStart != nil {
                if let session = await stopRecording() { showSessions(selecting: session.id) }
            } else {
                _ = await startRecording(name: nil)
            }
        }
    }

    /// Starts a session unless one is recording. False when sessions aren't available.
    func startRecording(name: String?) async -> Bool {
        guard let recorder else { return false }
        if model.recordingStart == nil {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setRecordingStart(await recorder.start(name: trimmed?.isEmpty == false ? trimmed : nil))
            updateDemand()
        }
        return true
    }

    /// Stops and saves the current session. Nil when none was recording.
    func stopRecording() async -> Session? {
        guard let recorder, model.recordingStart != nil else { return nil }
        let session = try? await recorder.stop()
        model.setRecordingStart(nil)
        updateDemand()
        return session
    }

    /// The latest readings in one sentence, for the Shortcuts action.
    func currentSummary() -> String {
        model.snapshot.map(MetricsExport.summary) ?? "No readings yet."
    }

    func showSessions(selecting id: UUID? = nil) {
        statusBar.closePanel()
        guard let database else { return }
        if sessionsWindow == nil {
            let sessions = SessionsModel(database: database)
            let window = NSWindow(contentViewController: NSHostingController(rootView: SessionsView(model: sessions)))
            window.title = "\(PulseInfo.appName) Sessions"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.center()
            sessionsWindow = window
            sessionsModel = sessions
        }
        sessionsModel?.reload(selecting: id)
        NSApp.activate()
        sessionsWindow?.makeKeyAndOrderFront(nil)
    }
}
