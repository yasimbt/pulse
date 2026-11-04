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

    init(model: LiveModel) {
        self.model = model
        super.init()
        // Closes when the user clicks elsewhere.
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
            appearance: appearance
        )
        let length = image.size.width + Self.itemPadding
        if entry.item.length != length { entry.item.length = length }

        // Updating a sublayer costs about 1.3 ms. Setting `button.image` costs about 16 ms, because
        // AppKit snapshots the item for MenuBarAgent. See docs/m1-findings.md.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.contentLayer.contents = image
        entry.contentLayer.frame = CGRect(
            x: Self.itemPadding / 2,
            y: (button.bounds.height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        CATransaction.commit()
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
            widthTemplate: config.kind == .network ? "↓999K ↑999K" : "100%",
            fillSteps: Int((min(1, max(0, reading.fraction)) * Double(StatusSegment.barSteps)).rounded()),
            spark: config.renderer == .sparkline ? spark(reading.series) : []
        )
    }

    private func spark(_ series: SeriesID) -> [Int] {
        let values = model.history.recentValues(series, count: StatusSegment.sparkColumns)
        let isFraction = series == .cpuTotal || series == .memoryUsed || series == .batteryCharge
        let scale = isFraction ? 1 : max(values.max() ?? 0, 1_000_000)
        return values.map { Int((min(1, $0 / scale) * Double(StatusSegment.sparkSteps)).rounded()) }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard layout.indices.contains(sender.tag) else { return }
        let kinds = layout[sender.tag]
        let host = NSHostingController(rootView: PanelHost(kinds: kinds, model: model, actions: actions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        onPanelChange?(Set(kinds))
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    /// Releases the SwiftUI views so that a closed panel costs no CPU.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        onPanelChange?(nil)
    }
}
