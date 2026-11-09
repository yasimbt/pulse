import AppKit
import PulseCore
import SwiftUI

/// Owns the menu-bar items and their popover.
///
/// Uses `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, whose scenes are fixed at compile
/// time and whose labels cannot draw custom graphics. Modules need user-set order and sparklines.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private final class Entry {
        let kinds: [ModuleKind]
        let item: NSStatusItem
        var lastSegments: [StatusSegment]?
        var lastAppearance: NSAppearance.Name?
        let contentLayer = CALayer()

        init(kinds: [ModuleKind], item: NSStatusItem) {
            self.kinds = kinds
            self.item = item
        }
    }

    private static let itemPadding: CGFloat = 10

    var actions = PanelActions(openSettings: {}, quit: {}, openActivityMonitor: {})
    var onPanelChange: ((Set<ModuleKind>?) -> Void)?

    private let model: LiveModel
    private var entries: [Entry] = []
    private var layout: [[ModuleKind]] = []
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var lastOutsideClose = ContinuousClock.Instant.now - .seconds(60)

    init(model: LiveModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Rebuilds the items if the module list changed. macOS puts each new item to the left of
    /// the existing ones, so they are added in reverse to get left-to-right order.
    func apply(_ settings: PulseSettings) {
        let enabled = settings.enabledModules.map(\.kind)
        let newLayout = settings.isCombined ? (enabled.isEmpty ? [] : [enabled]) : enabled.map { [$0] }
        if newLayout != layout {
            closePanel()
            entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
            layout = newLayout
            entries = newLayout.reversed().map(makeEntry)
        }
        // Forces a redraw, because the style or colour may have changed.
        entries.forEach { $0.lastSegments = nil }
    }

    func update(with settings: PulseSettings) {
        guard let snapshot = model.snapshot else { return }
        // One transaction for all items. Separate commits were the largest cost of a tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for entry in entries {
            let configs = entry.kinds.compactMap { kind in settings.modules.first { $0.kind == kind } }
            let parts = configs.compactMap { config -> (StatusSegment, ModuleReading)? in
                guard let reading = reading(config.kind, snapshot) else { return nil }
                return (segment(config, reading), reading)
            }
            // A layer isn't recoloured by macOS the way a template image is, so redraw on a change.
            let appearanceChanged = entry.lastAppearance != entry.item.button?.effectiveAppearance.name
            if parts.map(\.0) != entry.lastSegments || appearanceChanged {
                draw(entry, parts)
            }
        }
    }

    private func draw(_ entry: Entry, _ parts: [(StatusSegment, ModuleReading)]) {
        let segments = parts.map(\.0)
        entry.lastSegments = segments

        // A module with no data, such as Battery on a desktop Mac, is hidden.
        let isVisible = !segments.isEmpty
        if entry.item.isVisible != isVisible { entry.item.isVisible = isVisible }
        guard let button = entry.item.button else { return }
        let appearance = button.effectiveAppearance
        entry.lastAppearance = appearance.name
        let image = StatusItemRenderer.image(
            for: segments,
            scale: button.window?.backingScaleFactor ?? 2,
            appearance: appearance,
            compact: entry.kinds.count > 1
        )
        let length = image.size.width + Self.itemPadding
        if entry.item.length != length { entry.item.length = length }

        // Updating a sublayer costs about 1.3 ms. Setting `button.image` costs about 16 ms, because
        // AppKit snapshots the item for MenuBarAgent. See docs/m1-findings.md.
        // A CGImage, since Core Animation would otherwise convert an NSImage on every update.
        entry.contentLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        entry.contentLayer.frame = CGRect(
            x: Self.itemPadding / 2,
            y: (button.bounds.height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        button.setAccessibilityLabel(parts.map(\.1.accessibilityValue).joined(separator: ", "))
    }

    func closePanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func makeEntry(_ kinds: [ModuleKind]) -> Entry {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.wantsLayer = true
        item.button?.tag = layout.firstIndex(of: kinds) ?? 0
        let entry = Entry(kinds: kinds, item: item)
        item.button?.layer?.addSublayer(entry.contentLayer)
        return entry
    }

    private func reading(_ kind: ModuleKind, _ snapshot: Snapshot) -> ModuleReading? {
        ModuleReading.make(kind, snapshot: snapshot, recentPeak: kind == .network ? model.recentPeak(.networkDown) : 0)
    }

    private func segment(_ config: ModuleConfig, _ reading: ModuleReading) -> StatusSegment {
        StatusSegment(
            label: config.kind.shortLabel,
            renderer: config.renderer,
            tint: config.tint,
            text: reading.text,
            widthTemplate: Self.widthTemplate(config.kind),
            fillSteps: Int((min(1, max(0, reading.fraction)) * Double(StatusSegment.barSteps)).rounded()),
            spark: config.renderer == .sparkline ? spark(reading.series) : []
        )
    }

    private static func widthTemplate(_ kind: ModuleKind) -> String {
        switch kind {
        case .network: "↓999K ↑999K"
        case .power: "99.9W"
        case .ports: "⚡99W"
        default: "100%"
        }
    }

    private func spark(_ series: SeriesID) -> [Int] {
        let values = model.history.recentValues(series, count: StatusSegment.sparkColumns)
        let scale: Double = switch series {
        case .cpuTotal, .memoryUsed, .batteryCharge: 1
        case .powerCPU, .powerGPU, .powerTotal: max(values.max() ?? 0, 10)
        default: max(values.max() ?? 0, 1_000_000)
        }
        return values.map { Int((min(1, $0 / scale) * Double(StatusSegment.sparkSteps)).rounded()) }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A click on the icon may also reach the outside-click monitor. Don't reopen what it just closed.
        guard ContinuousClock.now - lastOutsideClose > .milliseconds(300) else { return }
        guard layout.indices.contains(sender.tag) else { return }
        let kinds = layout[sender.tag]
        let rootView = PanelHost(kinds: kinds, model: model, actions: actions) { [weak self] kind in
            self?.onPanelChange?([kind])
        }
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        onPanelChange?(Set(kinds.prefix(1)))
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        watchForOutsideClicks()
    }

    /// A transient popover only closes itself while this app is active, and macOS doesn't always
    /// activate a menu-bar app. A global monitor sees clicks in other apps. Mouse clicks don't
    /// need the Accessibility permission, and the event contents aren't used.
    private func watchForOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.lastOutsideClose = .now
                self.popover.performClose(nil)
            }
        }
    }

    /// Releases the SwiftUI views so that a closed panel costs no CPU.
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        popover.contentViewController = nil
        onPanelChange?(nil)
    }
}
