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
