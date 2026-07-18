import SwiftUI

/// Root content of the dictation panel: the full live HUD during a
/// dictation, the dimmed idle pill when persistent mode keeps the panel on
/// screen, nothing otherwise (the panel is ordered out for `.hidden`).
public struct DictationHUDRootView: View {
    @ObservedObject var state: DictationState
    @ObservedObject var modeStore: DictationModeStore
    @ObservedObject var presentationModel: DictationHUDPresentationModel
    let onStop: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onFixAccessibility: () -> Void
    let onStartDictation: () -> Void
    let onHidePill: () -> Void

    public init(
        state: DictationState,
        modeStore: DictationModeStore,
        presentationModel: DictationHUDPresentationModel,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {},
        onFixAccessibility: @escaping () -> Void = {},
        onStartDictation: @escaping () -> Void = {},
        onHidePill: @escaping () -> Void = {}
    ) {
        self.state = state
        self.modeStore = modeStore
        self.presentationModel = presentationModel
        self.onStop = onStop
        self.onCancel = onCancel
        self.onDismiss = onDismiss
        self.onFixAccessibility = onFixAccessibility
        self.onStartDictation = onStartDictation
        self.onHidePill = onHidePill
    }

    public var body: some View {
        switch presentationModel.presentation {
        case .idlePill(let recording):
            DictationIdlePillView(
                modeStore: modeStore,
                recording: recording,
                hovered: presentationModel.pillHovered,
                onHoverChange: { presentationModel.pillHovered = $0 },
                onStartDictation: onStartDictation,
                onHide: onHidePill
            )
        case .live, .hidden:
            // `.hidden` briefly renders during the fade-out — keep the live
            // HUD so the outgoing frame doesn't flicker to a pill.
            DictationHUDView(
                state: state,
                modeStore: modeStore,
                onStop: onStop,
                onCancel: onCancel,
                onDismiss: onDismiss,
                onFixAccessibility: onFixAccessibility
            )
        }
    }
}
