import PulseCore
import SwiftUI

struct PanelActions {
    let openSettings: () -> Void
    let quit: () -> Void
    let openActivityMonitor: () -> Void
}

/// Popover content: one module, or a picker when the combined item holds several.
struct PanelHost: View {
    let kinds: [ModuleKind]
    let model: LiveModel
    let actions: PanelActions
    @State private var selection: ModuleKind?

    private var current: ModuleKind? { selection ?? kinds.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kinds.count > 1 {
                Picker("Module", selection: Binding(get: { current }, set: { selection = $0 })) {
                    ForEach(kinds) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let current {
                ModulePanel(kind: current, model: model)
            }
            Divider()
            HStack {
                Button("Activity Monitor", action: actions.openActivityMonitor)
                Spacer()
                Button("Settings…", action: actions.openSettings)
                Button("Quit", action: actions.quit)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}
