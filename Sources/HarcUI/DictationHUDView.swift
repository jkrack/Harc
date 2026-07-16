import SwiftUI

/// Compact floating dictation indicator — mirrors SuperWhisper's mini recording
/// window. A glass capsule with a status dot, a live level waveform, and a stop
/// control. Hosted by a non-activating `NSPanel` so it never steals focus from
/// the app receiving the dictated text.
public struct DictationHUDView: View {
    @ObservedObject var state: DictationState
    let onStop: () -> Void
    let onCancel: () -> Void

    public init(
        state: DictationState,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onStop = onStop
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 10) {
            statusDot
            waveform
                .frame(width: 120, height: 22)
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
        case .transcribing, .inserting:
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
        case .error: return .orange
        case .idle: return .secondary
        }
    }

    private var statusText: String {
        switch state.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .error(let message): return message
        case .idle: return "Idle"
        }
    }

    private var accessibilityLabel: String {
        "Dictation: \(statusText)"
    }
}
