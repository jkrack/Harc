import SwiftUI
import KeyboardShortcuts

/// Compact floating dictation indicator — mirrors SuperWhisper's mini recording
/// window. A glass capsule with a status dot, a live level waveform, a mode
/// chip, and a stop control. Hosted by a non-activating `NSPanel` so it never
/// steals focus from the app receiving the dictated text.
public struct DictationHUDView: View {
    @ObservedObject var state: DictationState
    @ObservedObject var modeStore: DictationModeStore
    let onStop: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onFixAccessibility: () -> Void

    public init(
        state: DictationState,
        modeStore: DictationModeStore,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {},
        onFixAccessibility: @escaping () -> Void = {}
    ) {
        self.state = state
        self.modeStore = modeStore
        self.onStop = onStop
        self.onCancel = onCancel
        self.onDismiss = onDismiss
        self.onFixAccessibility = onFixAccessibility
    }

    public var body: some View {
        HStack(spacing: 10) {
            statusDot
            centerContent
                .frame(minWidth: 120, maxWidth: 260, minHeight: 22, alignment: .leading)
            if case .listening = state.phase {
                modeChip
                contextIndicator
            }
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
    }

    /// Waveform while listening; status text everywhere else. The old layout
    /// only showed text when the level history was empty — which meant
    /// "Transcribing…" and error messages could never render.
    @ViewBuilder
    private var centerContent: some View {
        if case .listening = state.phase {
            if micLooksSilent {
                Text("Mic is silent — check your input device")
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if state.levelHistory.isEmpty {
                statusLine
            } else {
                waveform
            }
        } else {
            statusLine
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.harcCaption)
            .foregroundStyle(statusTextColor)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var waveform: some View {
        GeometryReader { geo in
            let bars = state.levelHistory
            let count = max(bars.count, 1)
            let barWidth = max(1.5, (geo.size.width - CGFloat(count - 1) * 2) / CGFloat(DictationState.levelHistoryCount))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(dotColor.opacity(0.85))
                        .frame(width: barWidth, height: max(2, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// A full history of near-zero levels a couple of seconds into listening
    /// usually means the wrong input device or a muted mic — surface it
    /// instead of rendering flat bars (SuperWhisper's static-waveform hint).
    private var micLooksSilent: Bool {
        let recent = state.levelHistory.suffix(24)
        return recent.count >= 24 && recent.allSatisfy { $0 < 0.05 }
    }

    /// Active-mode chip. A menu — NSMenu tracking runs in its own window, so
    /// it works from a non-activating panel without stealing key status.
    /// When the session runs a different mode (per-app rule or one-shot
    /// hotkey), the chip shows that mode with an auto glyph instead.
    private var modeChip: some View {
        Menu {
            ForEach(modeStore.modes) { mode in
                Button {
                    modeStore.setActiveMode(id: mode.id)
                } label: {
                    if mode.id == modeStore.activeMode.id {
                        Label(Self.menuTitle(for: mode), systemImage: "checkmark")
                    } else {
                        Text(Self.menuTitle(for: mode))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chipMode.symbolName)
                    .font(.harcCaption)
                if state.sessionModeViaRule {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentColor)
                        .help("Activated by an app rule")
                }
                Text(chipTitle)
                    .font(.harcCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(state.sessionModeOverride == nil
              ? "Dictation mode"
              : "This dictation uses \(chipMode.name); the menu changes the default mode")
    }

    /// The mode the chip displays — the session override when one is in
    /// effect, the persisted active mode otherwise.
    private var chipMode: DictationMode {
        state.sessionModeOverride ?? modeStore.activeMode
    }

    /// Mode name plus its shortcut when one is recorded — SuperWhisper shows
    /// name + key in its mode display.
    private var chipTitle: String {
        let mode = chipMode
        if let shortcut = Self.shortcutLabel(for: mode) {
            return "\(mode.name)  \(shortcut)"
        }
        return mode.name
    }

    static func menuTitle(for mode: DictationMode) -> String {
        if let shortcut = shortcutLabel(for: mode) {
            return "\(mode.name)  \(shortcut)"
        }
        return mode.name
    }

    static func shortcutLabel(for mode: DictationMode) -> String? {
        KeyboardShortcuts.getShortcut(for: .dictationMode(mode.id))?.description
    }

    /// Lights when working context (selected text / clipboard) was captured
    /// for this session — SuperWhisper's context-capture indicator analog.
    /// Display-only; no interaction, so the non-activating panel stays inert.
    @ViewBuilder
    private var contextIndicator: some View {
        if state.context.hasWorkingMaterial {
            Image(systemName: "doc.text.viewfinder")
                .font(.harcCaption)
                .foregroundStyle(Color.accentColor)
                .help(contextHelp)
                .accessibilityLabel(contextHelp)
        }
    }

    private var contextHelp: String {
        let sources = [
            state.context.selectedText != nil ? "selected text" : nil,
            state.context.clipboardText != nil ? "clipboard" : nil,
        ].compactMap(\.self)
        return "Using \(sources.joined(separator: " + "))"
    }

    @ViewBuilder
    private var controls: some View {
        switch state.phase {
        case .listening:
            HStack(spacing: 6) {
                if state.confirmingCancel {
                    Button("Discard", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Click again to discard this dictation")
                } else {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel dictation")
                }
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(HarcBrand.live)
                }
                .buttonStyle(.plain)
                .help("Stop and insert")
            }
        case .requestingMic, .loadingModel, .loadingTransformModel, .transcribing,
             .transforming, .inserting:
            ProgressView()
                .controlSize(.small)
        case .done(let outcome):
            if outcome.needsAccessibility {
                Button("Open Settings", action: onFixAccessibility)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else if outcome.kind == .inserted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if outcome.kind == .notice {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
            }
        case .error:
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        case .idle:
            EmptyView()
        }
    }

    private var dotColor: Color {
        switch state.phase {
        case .requestingMic, .loadingModel, .loadingTransformModel: return .yellow
        case .listening: return HarcBrand.live
        case .transcribing, .inserting: return .accentColor
        case .transforming: return .indigo
        case .done(let outcome):
            switch outcome.kind {
            case .inserted: return .green
            case .copied: return .orange
            case .notice: return .accentColor
            }
        case .error: return .orange
        case .idle: return .secondary
        }
    }

    private var statusTextColor: Color {
        switch state.phase {
        // Outcomes and errors are the message — full contrast.
        case .done, .error: return .primary
        default: return .secondary
        }
    }

    private var statusText: String {
        switch state.phase {
        case .requestingMic: return "Waiting for microphone access…"
        case .loadingModel: return "Loading speech model…"
        case .loadingTransformModel(let name): return "Loading \(name)…"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .transforming: return "\(chipMode.name)…"
        case .inserting: return "Inserting…"
        case .done(let outcome): return outcome.message
        case .error(let message): return message
        case .idle: return state.notice ?? "Idle"
        }
    }

    private var accessibilityLabel: String {
        "Dictation: \(statusText), mode \(modeStore.activeMode.name)"
    }
}
