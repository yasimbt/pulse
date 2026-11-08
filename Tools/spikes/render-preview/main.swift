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
    let bat = BatteryCollector(), procs = ProcessCollector(), power = PowerCollector()
    await power.setDetail(true)
    // A few samples, so that charts and "since opened" have something to show.
    for index in 0..<6 {
        var snap = Snapshot(timestamp: Date())
        snap.cpu = try await cpu.sample(); snap.memory = try await mem.sample(); snap.disk = try await disk.sample()
        snap.network = try await net.sample(); snap.battery = try? await bat.sample(); snap.processes = try await procs.sample()
        snap.power = try? await power.sample()
        if index > 0 { model.ingest(snap, enabled: ModuleKind.allCases) }
        try await Task.sleep(for: .seconds(1))
    }

    // Menu-bar image: every renderer, every module, both layouts, in light and dark.
    for renderer in RendererKind.allCases {
        for compact in [false, true] {
            let segments = ModuleKind.allCases.map { kind in
                let reading = ModuleReading.make(kind, snapshot: model.snapshot ?? Snapshot(timestamp: Date()), recentPeak: 0)
                return StatusSegment(label: kind.shortLabel, renderer: renderer, tint: .system, text: reading?.text ?? "-",
                                     widthTemplate: kind == .network ? "↓999K ↑999K" : (kind == .power ? "99.9W" : "100%"),
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

    let actions = PanelActions(openSettings: {}, quit: {}, openActivityMonitor: {})
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
    for kinds in [ModuleKind.allCases, [.cpu, .memory], [.cpu], [.power]] as [[ModuleKind]] {
        let view = PanelHost(kinds: kinds, model: model, actions: actions).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/tabs-\(kinds.count)-\(kinds[0].rawValue).png"))
            print("tabs \(kinds.count): \(image.size)")
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
