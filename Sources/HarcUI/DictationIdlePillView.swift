import SwiftUI
import KeyboardShortcuts

/// The persistent idle pill — a dimmed compact glass capsule that stays on
/// screen when dictation is idle (pref-gated). Hover reveals controls:
/// start dictation, the mode menu, and a hide-until-next-dictation ✕.
/// Rendered inside the same non-activating panel as the live HUD, so
/// hovering and clicking never steal focus from the frontmost app.
public struct DictationIdlePillView: View {
    @ObservedObject var modeStore: DictationModeStore
    let recording: Bool
    let hovered: Bool
    let onHoverChange: (Bool) -> Void
    let onStartDictation: () -> Void
    let onHide: () -> Void

    public init(
        modeStore: DictationModeStore,
        recording: Bool,
        hovered: Bool,
        onHoverChange: @escaping (Bool) -> Void,
        onStartDictation: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.modeStore = modeStore
        self.recording = recording
        self.hovered = hovered
        self.onHoverChange = onHoverChange
        self.onStartDictation = onStartDictation
        self.onHide = onHide
    }

    public var body: some View {
        HStack(spacing: HarcSpacing.sm) {
            micGlyph
            if hovered {
                revealedControls
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, hovered ? 12 : 10)
        .padding(.vertical, HarcSpacing.sm)
        .glassEffect(in: Capsule())
        .opacity(hovered ? 1.0 : 0.55)
        .fixedSize()
        .contentShape(Capsule())
        .onHover(perform: onHoverChange)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recording
            ? "Dictation unavailable while recording"
            : "Dictation ready — mode \(modeStore.activeMode.name)")
    }

    @ViewBuilder
    private var micGlyph: some View {
        if recording {
            Image(systemName: "mic.fill")
                .font(.harcCaption)
                .foregroundStyle(HarcBrand.live.opacity(0.8))
                .help("Recording in progress — stop the recording to dictate")
        } else {
            Button(action: onStartDictation) {
                Image(systemName: "mic.fill")
                    .font(.harcCaption)
                    .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Start dictation")
        }
    }

    private var revealedControls: some View {
        HStack(spacing: HarcSpacing.sm) {
            // Same borderless Menu approach as the live HUD's chip — NSMenu
            // tracks in its own window, so no activation.
            Menu {
                ForEach(modeStore.modes) { mode in
                    Button {
                        modeStore.setActiveMode(id: mode.id)
                    } label: {
                        if mode.id == modeStore.activeMode.id {
                            Label(DictationHUDView.menuTitle(for: mode), systemImage: "checkmark")
                        } else {
                            Text(DictationHUDView.menuTitle(for: mode))
                        }
                    }
                }
            } label: {
                Text(modeStore.activeMode.name)
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Dictation mode")

            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide until the next dictation")
        }
    }
}
