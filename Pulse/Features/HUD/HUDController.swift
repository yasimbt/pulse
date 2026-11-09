import AppKit
import PulseCore
import SwiftUI

/// A small floating panel with live readings, for benchmarking or games. It floats above other
/// windows, including full-screen apps, appears on every desktop, and lets clicks pass through.
@MainActor
final class HUDController {
    private static let margin: CGFloat = 16

    private let model: LiveModel
    private var panel: NSPanel?
    private var corner = HUDSettings.Corner.topRight
    private var screenObserver: NSObjectProtocol?

    init(model: LiveModel) {
        self.model = model
    }

    func apply(_ settings: HUDSettings) {
        corner = settings.corner
        if settings.isVisible { show() } else { hide() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        // Dropped, so that its view stops redrawing every sample.
        panel = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame.size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            // Non-activating: showing it never takes focus from the game or app in front.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.place(panel)
            }
        }
        return panel
    }

    /// In the chosen corner of the main screen, inside the area the menu bar and Dock leave free.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let left = area.minX + Self.margin
        let right = area.maxX - size.width - Self.margin
        let bottom = area.minY + Self.margin
        let top = area.maxY - size.height - Self.margin
        let origin = switch corner {
        case .topLeft: NSPoint(x: left, y: top)
        case .topRight: NSPoint(x: right, y: top)
        case .bottomLeft: NSPoint(x: left, y: bottom)
        case .bottomRight: NSPoint(x: right, y: bottom)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// The HUD's readings, light text on a dark translucent card so that it reads over anything.
struct HUDView: View {
    let model: LiveModel

    var body: some View {
        let snapshot = model.snapshot
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            row("CPU", snapshot?.cpu.map { MetricFormat.percent($0.total) })
            row("GPU", snapshot?.power?.gpuActiveFraction.map(MetricFormat.percent))
            row("Power", snapshot?.power.flatMap { $0.cpuWatts == nil ? nil : MetricFormat.watts($0.totalWatts) })
            row("Chip", snapshot?.thermal?.reading("chipHottest").map { MetricFormat.temperature($0.celsius) })
            row("Memory", snapshot?.memory.map { MetricFormat.percent($0.usedFraction) })
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 150, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pulse heads-up display")
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Text(value ?? "–").frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
