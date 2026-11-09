import AppKit
import SwiftUI

/// Shown on first launch: where Pulse lives, and what to do if macOS hides it from the menu bar.
struct WelcomeView: View {
    let openSettings: () -> Void
    let done: () -> Void

    /// System Settings → Menu Bar, where macOS lists the apps allowed to show items there.
    static let menuBarSettings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Pulse").font(.largeTitle.weight(.semibold))
                Text("A menu-bar monitor for this Mac's CPU, memory, power and more.")
                    .foregroundStyle(.secondary)
            }
            step(
                "menubar.rectangle",
                "Pulse lives in the menu bar",
                "Look at the top right of the screen for items such as CPU and PWR. Click one for charts, the busiest "
                    + "processes, history and sessions. Pulse has no Dock icon."
            )
            step(
                "eye.slash",
                "Can't see it?",
                "macOS lets you choose which apps may show items in the menu bar. Open Menu Bar settings and make sure "
                    + "Pulse is allowed. On a MacBook with a notch, items can also hide behind it when the menu bar is "
                    + "full: try showing fewer modules, or all of them in one item."
            ) {
                Button("Open Menu Bar Settings") {
                    if let url = Self.menuBarSettings { NSWorkspace.shared.open(url) }
                }
            }
            step(
                "slider.horizontal.3",
                "Make it yours",
                "Choose modules and styles, turn on Launch at Login, alerts and the floating HUD in Settings."
            ) {
                Button("Open Settings", action: openSettings)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func step(
        _ symbol: String,
        _ title: String,
        _ text: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
