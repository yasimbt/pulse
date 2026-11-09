// Spike: render combined-mode UI offscreen with live data, because the terminal can't capture the screen.
// See the build line in Tools/spikes/render-preview/build.sh. Usage: render-preview <output dir>
import AppKit
import PulseCore
import SwiftUI

@MainActor
func save(_ view: NSView, _ path: String) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@MainActor
func run(_ out: String) async throws {
    _ = NSApplication.shared
    let model = LiveModel()
    let cpu = CPUCollector(), mem = MemoryCollector(), disk = DiskCollector(), net = NetworkCollector()
    let bat = BatteryCollector(), procs = ProcessCollector(), power = PowerCollector(), temperature = TemperatureCollector(), smc = SMCCollector(), ports = PortsCollector()
    await power.setDetail(true)
    // A few samples, so that charts and "since opened" have something to show.
    for index in 0..<6 {
        var snap = Snapshot(timestamp: Date())
        snap.cpu = try await cpu.sample(); snap.memory = try await mem.sample(); snap.disk = try await disk.sample()
        snap.network = try await net.sample(); snap.battery = try? await bat.sample(); snap.processes = try await procs.sample()
        snap.power = try? await power.sample()
        snap.thermal = try? await temperature.sample()
        snap.smc = try? await smc.sample()
        snap.ports = try? await ports.sample()
        if index > 0 { model.ingest(snap, enabled: ModuleKind.allCases) }
        try await Task.sleep(for: .seconds(1))
    }

    // Menu-bar image: every renderer, every module, both layouts, in light and dark.
    for renderer in RendererKind.allCases {
        for compact in [false, true] {
            let segments = ModuleKind.allCases.map { kind in
                let reading = ModuleReading.make(kind, snapshot: model.snapshot ?? Snapshot(timestamp: Date()), recentPeak: 0)
                return StatusSegment(label: kind.shortLabel, renderer: renderer, tint: .system, text: reading?.text ?? "-",
                                     widthTemplate: kind == .network ? "↓999K ↑999K" : (kind == .power ? "99.9W" : (kind == .ports ? "⚡99W" : "100%")),
                                     fillSteps: 14, spark: (0..<18).map { 2 + ($0 * 3) % 12 })
            }
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = NSAppearance(named: appearanceName) ?? .currentDrawing()
                let image = StatusItemRenderer.image(for: segments, scale: 4, appearance: appearance, compact: compact)
                if name == "light" { print("menu \(renderer.rawValue) compact=\(compact): \(image.size.width) pt") }
                let holder = NSView(frame: NSRect(x: 0, y: 0, width: image.size.width + 8, height: 26))
                holder.wantsLayer = true
                holder.layer?.backgroundColor = (name == "light" ? NSColor.white : NSColor.black).cgColor
                let view = NSImageView(frame: NSRect(x: 4, y: 4, width: image.size.width, height: image.size.height))
                view.image = image
                holder.addSubview(view)
                save(holder, "\(out)/menu-\(renderer.rawValue)-\(compact ? "compact" : "full")-\(name).png")
            }
        }
    }

    let actions = PanelActions(openSettings: {}, quit: {}, openActivityMonitor: {}, openHistory: {})
    for kind in ModuleKind.allCases {
        let rest = ModuleKind.allCases.filter { $0 != kind }
        let host = NSHostingView(rootView: PanelHost(kinds: [kind] + rest, model: model, actions: actions))
        let size = host.fittingSize
        print("panel \(kind.rawValue): \(size.width) x \(size.height)")
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        save(host, "\(out)/panel-\(kind.rawValue).png")
    }
    // ImageRenderer draws pure SwiftUI faithfully. AppKit-backed controls such as buttons show as placeholders.
    for kinds in [ModuleKind.allCases, [.cpu, .memory], [.cpu], [.power], [.ports]] as [[ModuleKind]] {
        let view = PanelHost(kinds: kinds, model: model, actions: actions).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/tabs-\(kinds.count)-\(kinds[0].rawValue).png"))
            print("tabs \(kinds.count): \(image.size)")
        }
    }
    try await renderHistory(out)
    try await captureSettings(out, model: model)
    // The HUD, on a mid-grey background as it might sit over a game.
    let hud = NSHostingView(rootView: HUDView(model: model).padding(20).background(Color(white: 0.45)))
    hud.frame = NSRect(origin: .zero, size: hud.fittingSize)
    let hudWindow = NSWindow(contentRect: hud.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    hudWindow.contentView = hud
    hud.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    save(hud, "\(out)/hud.png")
    try await benchmarkFullDay(out)
    try await captureHistoryWindow(out, size: NSSize(width: 960, height: 720))
    try await captureHistoryWindow(out, size: NSSize(width: 860, height: 560))
}

/// M3 acceptance: a full day of synthetic history, stored the way a day of sampling would leave it,
/// then loaded and drawn at 24 h. Uses a temporary file.
@MainActor
func benchmarkFullDay(_ out: String) async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "pulse-day-\(UUID().uuidString).sqlite")
    let database = try HistoryDatabase.open(at: url)
    let now = Date()
    let rows = (0..<86_400).map { second -> HistoryRow in
        let wave = (sin(Double(second) / 600) + 1) / 2
        return HistoryRow(time: now.addingTimeInterval(Double(second - 86_400)), values: [
            .cpuTotal: 0.1 + 0.6 * wave, .memoryUsed: 0.7, .powerCPU: 1 + 15 * wave, .powerGPU: 0.2,
            .networkDown: 1e6 * wave, .networkUp: 2e5, .diskRead: 3e6 * wave, .diskWrite: 1e6, .batteryCharge: 0.9 - 0.5 * Double(second) / 86_400
        ])
    }
    try database.insert(rows)
    try database.rollUpAndPrune(now: now)
    let history = HistoryModel(store: HistoryStore(database: database))
    history.span = 86_400
    try await Task.sleep(for: .seconds(2))
    let clock = ContinuousClock()
    let started = clock.now
    let view = VStack(alignment: .leading, spacing: 16) {
        ForEach(history.visibleGroups) { TimelineChart(group: $0, model: history) }
    }
    .padding(12).frame(width: 700).background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = renderer.nsImage
    let points = history.loaded.values.map(\.count).reduce(0, +)
    print("full day: \(points) points loaded in \(Int(history.lastLoadMilliseconds ?? -1)) ms, drawn in \(clock.now - started)")
    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/history-full-day.png"))
    }
    try? FileManager.default.removeItem(at: url)
}

/// The whole history window as AppKit lays it out, in a borderless offscreen window at the size
/// the app opens it with. Unlike ImageRenderer, this draws scroll views and system controls.
@MainActor
func captureHistoryWindow(_ out: String, size: NSSize) async throws {
    let store = HistoryStore(database: try HistoryDatabase.open(at: HistoryStore.defaultURL))
    let model = HistoryModel(store: store)
    try await Task.sleep(for: .seconds(2))
    model.selection = Date().addingTimeInterval(-120)
    try await Task.sleep(for: .milliseconds(600))
    let host = NSHostingView(rootView: HistoryView(model: model))
    host.appearance = NSAppearance(named: .aqua)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(500))
    print("history window \(Int(size.width))x\(Int(size.height)): fitting \(host.fittingSize)")
    save(host, "\(out)/history-window-\(Int(size.width)).png")
}

/// The Settings window as AppKit lays it out, with alerts and rules switched on for the picture.
@MainActor
func captureSettings(_ out: String, model: LiveModel) async throws {
    // A throwaway defaults domain, so that the real settings are never touched.
    let store = SettingsStore(defaults: UserDefaults(suiteName: "com.pulse.preview") ?? .standard)
    var settings = store.settings
    settings.alerts = AlertSettings(enabled: [.chipTemperature, .lowDiskSpace], chipCelsius: 95, swapGrowthBytes: 2e9,
                                    minimumFreeBytes: 10e9, minimumBatteryHealth: 0.8)
    settings.rules = RuleSettings(onBattery: RuleActions(sampleInterval: 5, hiddenModules: [.power]), lowPowerMode: .none)
    settings.metricsServerPort = 9466
    store.settings = settings
    let host = NSHostingView(rootView: SettingsView(store: store, model: model))
    host.appearance = NSAppearance(named: .aqua)
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(500))
    print("settings: \(size)")
    save(host, "\(out)/settings.png")
}

/// The history window, from this Mac's real history file. Only reads it.
@MainActor
func renderHistory(_ out: String) async throws {
    let store = HistoryStore(database: try HistoryDatabase.open(at: HistoryStore.defaultURL))
    for (name, span) in [("1h", 3600.0), ("24h", 86400.0)] {
        let history = HistoryModel(store: store)
        history.span = span
        try await Task.sleep(for: .seconds(2))
        history.selection = Date().addingTimeInterval(-120)
        try await Task.sleep(for: .milliseconds(600))
        // ImageRenderer leaves ScrollView contents blank, so the charts are drawn without one.
        let view = VStack(alignment: .leading, spacing: 16) {
            ForEach(history.visibleGroups) { TimelineChart(group: $0, model: history) }
        }
        .padding(12).frame(width: 700).background(Color.white)
        if let time = history.selection {
            let values = HistoryModel.groups.flatMap { group in
                group.lines.map { "\(group.id) \(group.lines.count > 1 ? $0.name : "")=\(history.value(of: $0.series, at: time).map { HistoryFormat.value($0, group.scale) } ?? "-")" }
            }
            print("readout at \(time.formatted(date: .omitted, time: .standard)): \(values.joined(separator: ", "))")
            print("processes: \(history.processes.prefix(5).map { "\($0.name) \(MetricFormat.cores($0.cpuCores))" }.joined(separator: ", "))")
        }
        let clock = ContinuousClock()
        let started = clock.now
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = renderer.nsImage
        print("history \(name): load \(Int(history.lastLoadMilliseconds ?? -1)) ms, render \(clock.now - started)")
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/history-\(name).png"))
        }
    }
}

@main
struct Main {
    static func main() async throws {
        try await run(CommandLine.arguments[1])
        exit(0)
    }
}
