// Spike: CPU cost of updating one status item once per second, by drawing strategy.
// Build: swiftc -o /tmp/sic Tools/spikes/statusitem-cost/main.swift
// Run:   /tmp/sic <mode> [updatesPerSecond]
// Modes: idle, tmpl40, plain40, tmpl200, plain200, title, layer
import AppKit

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "idle"
let rate = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1 : 1

func bitmapImage(width: CGFloat, value: Int, template: Bool) -> NSImage {
    let size = NSSize(width: width, height: 18)
    let image = NSImage(size: size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 36, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 4, width: CGFloat(value % Int(width)), height: 10).fill()
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
    image.isTemplate = template
    return image
}

@MainActor
final class Spike: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var value = 0
    let sublayer = CALayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = bitmapImage(width: mode.hasSuffix("200") ? 200 : 40, value: 1, template: !mode.hasPrefix("plain"))
        if mode == "layer", let button = item.button {
            button.wantsLayer = true
            sublayer.frame = CGRect(x: 0, y: 2, width: 40, height: 18)
            button.layer?.addSublayer(sublayer)
        }
        guard mode != "idle" else { return }
        Timer.scheduledTimer(withTimeInterval: 1 / rate, repeats: true) { _ in
            MainActor.assumeIsolated { self.step() }
        }
    }

    func step() {
        value += 7
        switch mode {
        case "tmpl40": item.button?.image = bitmapImage(width: 40, value: value, template: true)
        case "plain40": item.button?.image = bitmapImage(width: 40, value: value, template: false)
        case "tmpl200": item.button?.image = bitmapImage(width: 200, value: value, template: true)
        case "plain200": item.button?.image = bitmapImage(width: 200, value: value, template: false)
        case "title": item.button?.title = "\(value % 100)%"
        case "layer":
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sublayer.contents = bitmapImage(width: 40, value: value, template: false)
            CATransaction.commit()
        default: break
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Spike() }
app.delegate = delegate
app.run()
