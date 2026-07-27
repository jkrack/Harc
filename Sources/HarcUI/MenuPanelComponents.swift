import SwiftUI

// Shared building blocks for the menu-bar panel. Every clickable surface
// gets a full-width hit area and hover feedback, matching native menu rows
// instead of bare text links.

/// A menu-item-style row: full-width click target, hover highlight,
/// leading icon, optional trailing detail (keyboard-shortcut hint).
struct MenuPanelRowButton: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.harcBody)
                    .foregroundStyle(tint ?? Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.harcBody)
                    .foregroundStyle(tint ?? Color.primary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.harcBody)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A small inline action (readiness "Fix", footer links): caption text in a
/// hover-highlighted capsule so the target is bigger than the glyphs.
struct HoverPillButton: View {
    let title: String
    var tint: Color = .accentColor
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.harcCaption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(hovering ? tint.opacity(0.14) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Icon-only control with a real (≥24pt) hover-highlighted hit area —
/// for the history clock and similar compact affordances.
struct HoverIconButton<Menu: View>: View {
    let icon: String
    let help: String
    @ViewBuilder let menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        SwiftUI.Menu {
            menu()
        } label: {
            Image(systemName: icon)
                .font(.harcBody)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
    }
}
