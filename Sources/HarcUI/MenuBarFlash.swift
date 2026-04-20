import AppKit

/// Briefly swaps a status-item's icon for a symbol that indicates the
/// outcome of an auto-paste attempt, then calls a caller-supplied
/// `restore` closure to return to whatever idle/recording icon was
/// previously displayed.
///
/// All methods require @MainActor. The helper is stateless beyond the
/// Task that schedules the restore; overlapping flashes simply restore
/// to the last-known state via the most recent `restore` closure.
@MainActor
public final class MenuBarFlash {
    public init() {}

    /// Green checkmark — paste succeeded.
    public func flashSuccess(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "checkmark.circle.fill",
            tint: .systemGreen,
            tooltip: nil,
            duration: duration,
            restore: restore
        )
    }

    /// Red exclamation — paste attempt failed (accessibility denied, etc.).
    public func flashFailure(
        on item: NSStatusItem,
        duration: TimeInterval = 0.8,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "exclamationmark.circle.fill",
            tint: .systemRed,
            tooltip: nil,
            duration: duration,
            restore: restore
        )
    }

    /// Amber raised hand — paste intentionally skipped (unsafe target,
    /// deny-list match). Longer duration + tooltip gives the user time to
    /// read why.
    public func flashSkipped(
        on item: NSStatusItem,
        tooltip: String,
        duration: TimeInterval = 1.2,
        restore: @escaping @MainActor () -> Void
    ) {
        flash(
            item,
            symbol: "hand.raised.fill",
            tint: .systemOrange,
            tooltip: tooltip,
            duration: duration,
            restore: restore
        )
    }

    private func flash(
        _ item: NSStatusItem,
        symbol: String,
        tint: NSColor,
        tooltip: String?,
        duration: TimeInterval,
        restore: @escaping @MainActor () -> Void
    ) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = tint
        button.toolTip = tooltip
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            button.toolTip = nil
            button.contentTintColor = nil
            restore()
        }
    }
}
