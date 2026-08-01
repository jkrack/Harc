import AppKit
import SwiftUI
import HarcUI

/// Spotlight-style host for Quick Capture. Unlike the island and the
/// dictation HUD this panel must accept typing (the name field is the whole
/// point), so it becomes key — but stays a non-activating panel, which
/// keeps the frontmost app active underneath: start the recording and you
/// are still in your meeting window, not in Harc.
@MainActor
final class QuickCapturePanel {

    /// Borderless panels refuse key status by default; the name field needs it.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
        var onCancel: (() -> Void)?
    }

    private let panel: KeyablePanel
    private var resignObserver: NSObjectProtocol?

    init(rootView: some View, onDismiss: @escaping @MainActor @Sendable () -> Void) {
        let hosting = NSHostingController(rootView: AnyView(rootView))
        hosting.view.layoutSubtreeIfNeeded()

        panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setContentSize(hosting.view.fittingSize)
        panel.onCancel = onDismiss

        // Clicking anywhere else is a cancel — Spotlight's contract.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in onDismiss() }
        }
    }

    // Observer cleanup happens in hide() rather than deinit — a nonisolated
    // deinit can't touch main-actor state, and the panel is discarded right
    // after hide() anyway.

    var isVisible: Bool { panel.isVisible }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Design 3a: horizontally centered, upper third of the screen.
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.16
        ))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel.orderOut(nil)
    }
}
