import AppKit
import Combine
import SwiftUI
import HarcUI

/// Borderless, non-activating floating panel that hosts the dictation HUD
/// (live view during a dictation, dimmed idle pill when the persistent-pill
/// preference keeps it on screen).
///
/// **Critical:** it must never become the active app or steal keyboard focus.
/// Dictation inserts text into whatever app is frontmost via a synthetic Cmd-V,
/// so if this panel activated Harc the paste would land in the wrong place (or
/// nowhere). `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` keeps focus on the
/// target app even when the user clicks the HUD's stop button — and the idle
/// pill's hover-revealed controls run under the same constraints.
@MainActor
final class DictationHUDPanel {
    private let panel: NSPanel
    private let hosting: NSHostingController<DictationHUDRootView>
    private let presentationModel: DictationHUDPresentationModel
    private var observers: Set<AnyCancellable> = []
    private var isVisible = false

    init(
        state: DictationState,
        modeStore: DictationModeStore,
        presentationModel: DictationHUDPresentationModel,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {},
        onFixAccessibility: @escaping () -> Void = {},
        onStartDictation: @escaping () -> Void = {},
        onHidePill: @escaping () -> Void = {},
        onConfirmDeepLink: @escaping () -> Void = {},
        onDismissDeepLink: @escaping () -> Void = {}
    ) {
        self.presentationModel = presentationModel
        let hosting = NSHostingController(
            rootView: DictationHUDRootView(
                state: state,
                modeStore: modeStore,
                presentationModel: presentationModel,
                onStop: onStop,
                onCancel: onCancel,
                onDismiss: onDismiss,
                onFixAccessibility: onFixAccessibility,
                onStartDictation: onStartDictation,
                onHidePill: onHidePill,
                onConfirmDeepLink: onConfirmDeepLink,
                onDismissDeepLink: onDismissDeepLink
            )
        )
        self.hosting = hosting
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

        // The capsule's size changes with phase (waveform vs status text vs
        // end-state message), with presentation (live HUD vs pill), and with
        // the pill's hover reveal — re-fit and re-center so nothing clips.
        state.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refitIfVisible() }
            .store(in: &observers)
        presentationModel.$presentation
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refitIfVisible() }
            .store(in: &observers)
        presentationModel.$pillHovered
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refitIfVisible() }
            .store(in: &observers)
    }

    /// Route a computed presentation to panel state. The model is set first
    /// so SwiftUI renders the right content before the panel fades in.
    func apply(_ presentation: DictationHUDPresentation) {
        presentationModel.presentation = presentation
        switch presentation {
        case .hidden:
            hide()
        case .idlePill, .live, .confirmDeepLink:
            show()
        }
    }

    func show() {
        refit()
        position()
        if !isVisible {
            isVisible = true
            panel.alphaValue = 0
            // orderFrontRegardless shows the panel without activating Harc.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        presentationModel.pillHovered = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    private func refitIfVisible() {
        guard isVisible else { return }
        refit()
        position()
    }

    private func refit() {
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
    }

    /// Bottom-center of the screen the user is working on — the one holding
    /// the pointer (a good proxy for the focused app's screen) — falling back
    /// to the main screen.
    private func position() {
        panel.layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
