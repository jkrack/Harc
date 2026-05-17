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
        HStack(spacing: 6) {
            Button(action: onAccept) {
                HStack(spacing: 6) {
                    Image(systemName: "person.wave.2")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Text(titleLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(percentText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(suggestion.name == nil)

            if suggestion.name != nil {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss suggestion")
                .padding(.trailing, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
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
