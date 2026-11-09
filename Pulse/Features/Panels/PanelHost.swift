import PulseCore
import SwiftUI

struct PanelActions {
    let openSettings: () -> Void
    let quit: () -> Void
    let openActivityMonitor: () -> Void
    /// Nil when history isn't available, which hides the button.
    var openHistory: (() -> Void)?
    /// Nil when sessions aren't available, which hides the Record button.
    var toggleRecording: (() -> Void)?
    var openSessions: (() -> Void)?
}

/// Popover content: one module, or a picker when the combined item holds several.
struct PanelHost: View {
    let kinds: [ModuleKind]
    let model: LiveModel
    let actions: PanelActions
    /// Lets the sampler run `nettop` only while the Network tab is showing.
    var onTabChange: (ModuleKind) -> Void = { _ in }
    @State private var selection: ModuleKind?

    private var current: ModuleKind? { selection ?? kinds.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kinds.count > 1 {
                ModuleTabs(kinds: kinds, selected: current) {
                    selection = $0
                    onTabChange($0)
                }
            }
            if let current {
                ModulePanel(kind: current, model: model)
            }
            Divider()
            VStack(spacing: 8) {
                HStack {
                    if let toggleRecording = actions.toggleRecording {
                        RecordButton(start: model.recordingStart, action: toggleRecording)
                    }
                    Spacer()
                    if let openSessions = actions.openSessions {
                        Button("Sessions…", action: openSessions)
                    }
                    if let openHistory = actions.openHistory {
                        Button("History…", action: openHistory)
                    }
                }
                HStack {
                    Button("Activity Monitor", action: actions.openActivityMonitor)
                    Spacer()
                    Button("Settings…", action: actions.openSettings)
                    Button("Quit", action: actions.quit)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// Starts or stops a workload session, showing how long the current one has run.
struct RecordButton: View {
    let start: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let start {
                // Redraws once a second, only while recording and only while the panel is open.
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Label("Stop  \(MetricFormat.clock(context.date.timeIntervalSince(start)))", systemImage: "stop.fill")
                        .monospacedDigit()
                }
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .tint(start == nil ? nil : .red)
        .help(start == nil
            ? "Record a workload session (\(HotKey.Shortcut.record.title))"
            : "Stop and show the summary (\(HotKey.Shortcut.record.title))")
    }
}

/// Equal-width tabs that always fit the panel. A system segmented control sizes itself to its
/// titles, and five of them left almost no margin, so tabs could be clipped at the panel's edges.
struct ModuleTabs: View {
    let kinds: [ModuleKind]
    let selected: ModuleKind?
    let select: (ModuleKind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds) { kind in
                let isSelected = kind == selected
                Button { select(kind) } label: {
                    Text(kind.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
