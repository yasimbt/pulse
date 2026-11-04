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
    let bat = BatteryCollector(), procs = ProcessCollector()
    var snap = Snapshot(timestamp: Date())
    for _ in 0..<2 {
        snap = Snapshot(timestamp: Date())
        snap.cpu = try await cpu.sample(); snap.memory = try await mem.sample(); snap.disk = try await disk.sample()
        snap.network = try await net.sample(); snap.battery = try? await bat.sample(); snap.processes = try await procs.sample()
        try await Task.sleep(for: .seconds(1))
    }
    model.ingest(snap, enabled: ModuleKind.allCases)

    // Menu-bar image: every renderer, all five modules.
    for renderer in RendererKind.allCases {
        let segments = ModuleKind.allCases.map { kind in
            let reading = ModuleReading.make(kind, snapshot: snap, recentPeak: 0)
            return StatusSegment(label: kind.shortLabel, renderer: renderer, tint: .blue, text: reading?.text ?? "-",
                                 widthTemplate: kind == .network ? "↓999K ↑999K" : "100%",
                                 fillSteps: 14, spark: Array(repeating: 7, count: 18))
        }
        let image = StatusItemRenderer.image(for: segments)
        print("menu \(renderer.rawValue): \(image.size.width) pt")
        let holder = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        holder.image = image
        save(holder, "\(out)/menu-\(renderer.rawValue).png")
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
    for kinds in [ModuleKind.allCases, [.cpu, .memory], [.cpu]] as [[ModuleKind]] {
        let view = PanelHost(kinds: kinds, model: model, actions: actions).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/tabs-\(kinds.count).png"))
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
