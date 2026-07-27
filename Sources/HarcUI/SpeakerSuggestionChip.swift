import SwiftUI

/// One "Sounds like Jason · 3 prior recordings (84 %)" chip shown beneath a
/// speaker row in `SpeakerNameEditor`. Clicking the body applies the name;
/// `×` dismisses just this chip for the current session.
public struct SpeakerSuggestionChip: View {
    public let suggestion: SpeakerSuggestion
    public let onAccept: () -> Void
    public let onDismiss: () -> Void

    public init(
        suggestion: SpeakerSuggestion,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.suggestion = suggestion
        self.onAccept = onAccept
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: HarcSpacing.sm) {
            Button(action: onAccept) {
                HStack(spacing: HarcSpacing.sm) {
                    Image(systemName: "person.wave.2")
                        .font(.harcCaption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Text(titleLine)
                        .font(.harcLabel)
                        .foregroundStyle(Color.primary)
                    Text(percentText)
                        .font(.harcCaption.monospaced())
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(.leading, HarcSpacing.sm)
                .padding(.trailing, HarcSpacing.xs)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(suggestion.name == nil)

            if suggestion.name != nil {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.harcCaption.weight(.medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .padding(HarcSpacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestion")
                .padding(.trailing, HarcSpacing.xs)
            }
        }
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var titleLine: String {
        if let name = suggestion.name {
            let priorCount = suggestion.matches.count
            let tail = priorCount == 1 ? "1 prior recording" : "\(priorCount) prior recordings"
            return "Sounds like \(name) · \(tail)"
        } else {
            return "Sounds like a speaker from an earlier recording"
        }
    }

    private var percentText: String {
        let pct = Int((suggestion.bestSimilarity * 100).rounded())
        return "\(pct) %"
    }
}
