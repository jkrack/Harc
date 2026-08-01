import AppKit
import SwiftUI
import HarcUI

/// Panel host for the recording island — the DictationHUDPanel pattern
/// pointed at the top of the screen. Non-activating, floats above every
/// app and space, draggable by its body, and only exists while a recording
/// (or its save/discard tail) does.
///
/// When the Library window is frontmost the island dims to 40% instead of
/// hiding: the same recording is on screen twice, and only one of them
/// should read at full strength.
@MainActor
final class RecordingIslandPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<AnyView>
    /// True while the user has dragged the island somewhere; stops the
    /// positioner from yanking it back to top-center on every re-show.
    private var userMoved = false
    private var lastAutoOrigin: NSPoint?
    private var keyObservers: [NSObjectProtocol] = []
    private let isLibraryFrontmost: () -> Bool

    init(rootView: some View, isLibraryFrontmost: @escaping () -> Bool) {
        self.isLibraryFrontmost = isLibraryFrontmost
        hosting = NSHostingController(rootView: AnyView(rootView))
        hosting.view.layoutSubtreeIfNeeded()

        panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the SwiftUI capsule draws its own
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.setContentSize(hosting.view.fittingSize)

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDimming() }
            })
        }
        keyObservers.append(center.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteMove() }
        })
    }

    // No deinit observer cleanup: the panel lives for the app's lifetime
    // (AppDelegate holds it), and block-based observers die with the
    // process. A nonisolated deinit can't touch the main-actor array anyway.

    var isVisible: Bool { panel.isVisible }

    func show() {
        refit()
        if !panel.isVisible {
            userMoved = false
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = targetAlpha
            }
        } else {
            refreshDimming()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    /// Content size follows the pill's state (34pt resting → 52pt hovered).
    func refit() {
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let anchored = panel.frame
        // Keep the pill centered on its own midpoint as it grows/shrinks.
        let origin = NSPoint(
            x: anchored.midX - size.width / 2,
            y: anchored.maxY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Design 3b: top-center, tucked just under the menu bar.
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 8
        )
        lastAutoOrigin = origin
        panel.setFrameOrigin(origin)
    }

    private func noteMove() {
        // Ignore the moves we caused; any other move is the user dragging.
        guard let auto = lastAutoOrigin else { userMoved = true; return }
        if abs(panel.frame.origin.x - auto.x) > 2 || abs(panel.frame.origin.y - auto.y) > 2 {
            userMoved = true
        }
    }

    private var targetAlpha: CGFloat {
        isLibraryFrontmost() ? 0.4 : 1.0
    }

    private func refreshDimming() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = targetAlpha
        }
    }
}
