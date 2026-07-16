import AppKit
import SwiftUI
import HarcUI

/// Borderless, non-activating floating panel that hosts the dictation HUD.
///
/// **Critical:** it must never become the active app or steal keyboard focus.
/// Dictation inserts text into whatever app is frontmost via a synthetic Cmd-V,
/// so if this panel activated Harc the paste would land in the wrong place (or
/// nowhere). `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` keeps focus on the
/// target app even when the user clicks the HUD's stop button.
@MainActor
final class DictationHUDPanel {
    private let panel: NSPanel

    init(
        state: DictationState,
        modeStore: DictationModeStore,
        prefs: HarcPreferences,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let hosting = NSHostingController(
            rootView: DictationHUDView(
                state: state,
                modeStore: modeStore,
                prefs: prefs,
                onStop: onStop,
                onCancel: onCancel
            )
        )
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.setContentSize(hosting.view.fittingSize)
        self.panel = panel
    }

    func show() {
        positionBottomCenter()
        // orderFrontRegardless shows the panel without activating Harc.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionBottomCenter() {
        panel.layoutIfNeeded()
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
