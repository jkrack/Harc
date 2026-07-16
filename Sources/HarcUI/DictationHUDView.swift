import SwiftUI

/// Compact floating dictation indicator — mirrors SuperWhisper's mini recording
/// window. A glass capsule with a status dot, a live level waveform, a mode
/// chip, and a stop control. Hosted by a non-activating `NSPanel` so it never
/// steals focus from the app receiving the dictated text.
public struct DictationHUDView: View {
    @ObservedObject var state: DictationState
    @ObservedObject var modeStore: DictationModeStore
    @ObservedObject var prefs: HarcPreferences
    let onStop: () -> Void
    let onCancel: () -> Void

    public init(
        state: DictationState,
        modeStore: DictationModeStore,
        prefs: HarcPreferences,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.modeStore = modeStore
        self.prefs = prefs
        self.onStop = onStop
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            statusDot
            waveform
                .frame(width: 120, height: 22)
            modeChip
            contextIndicator
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

    @ViewBuilder
    private var waveform: some View {
        GeometryReader { geo in
            let bars = state.levelHistory
            let count = max(bars.count, 1)
            let barWidth = max(1.5, (geo.size.width - CGFloat(count - 1) * 2) / CGFloat(DictationState.levelHistoryCount))
            HStack(alignment: .center, spacing: 2) {
                if bars.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(dotColor.opacity(0.85))
                            .frame(width: barWidth, height: max(2, geo.size.height * CGFloat(level)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Active-mode chip. A menu — NSMenu tracking runs in its own window, so
    /// it works from a non-activating panel without stealing key status.
    private var modeChip: some View {
        Menu {
            ForEach(modeStore.modes) { mode in
                Button {
                    modeStore.setActiveMode(id: mode.id)
                } label: {
                    if mode.id == modeStore.activeMode.id {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Text(mode.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: modeStore.activeMode.symbolName)
                    .font(.caption2)
                Text(modeStore.activeMode.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Dictation mode")
    }

    /// Lights when working context (selected text / clipboard) was captured
    /// for this session — SuperWhisper's context-capture indicator analog.
    /// Display-only; no interaction, so the non-activating panel stays inert.
    @ViewBuilder
    private var contextIndicator: some View {
        if state.context.hasWorkingMaterial {
            Image(systemName: "doc.text.viewfinder")
                .font(.caption2)
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
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(HarcBrand.live)
                }
                .buttonStyle(.plain)
            }
        case .transcribing, .transforming, .inserting:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var dotColor: Color {
        switch state.phase {
        case .listening: return HarcBrand.live
        case .transcribing, .inserting: return .accentColor
        case .transforming: return .indigo
        case .error: return .orange
        case .idle: return .secondary
        }
    }

    private var statusText: String {
        switch state.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .transforming: return "\(modeStore.activeMode.name)…"
        case .inserting: return "Inserting…"
        case .error(let message): return message
        case .idle: return state.notice ?? "Idle"
        }
    }

    private var accessibilityLabel: String {
        "Dictation: \(statusText), mode \(modeStore.activeMode.name)"
    }
}
