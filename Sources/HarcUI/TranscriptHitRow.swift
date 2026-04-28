import SwiftUI
import HarcStore

/// Single search-results row — recording header + highlighted transcript
/// snippet. Double-tap opens the detail window (parent passes `onOpen`).
public struct TranscriptHitRow: View {
    public let hit: TranscriptHit
    public let onOpen: () -> Void

    public init(hit: TranscriptHit, onOpen: @escaping () -> Void) {
        self.hit = hit
        self.onOpen = onOpen
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            let accent: Color = hit.recording.pinned ? .purple : .accentColor
            let icon: String = hit.recording.pinned ? "pin.fill" : "waveform"
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14.72, weight: .semibold))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(hit.recording.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(RelativeTimeFormatter.format(hit.recording.startedAt))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Text(TranscriptHitRow.highlight(hit.snippet))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }

    /// Convert a snippet containing literal "<mark>…</mark>" spans into an
    /// AttributedString where matched tokens get accentColor tint on
    /// a translucent accent background. Pure string walk — no HTML.
    public static func highlight(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(snippet)
        let open: Substring = "<mark>"
        let close: Substring = "</mark>"

        while let openRange = rest.range(of: open) {
            var plain = AttributedString(String(rest[..<openRange.lowerBound]))
            plain.foregroundColor = Color.secondary
            out += plain

            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                var tail = AttributedString(String(afterOpen))
                tail.foregroundColor = Color.secondary
                out += tail
                return out
            }

            var marked = AttributedString(String(afterOpen[..<closeRange.lowerBound]))
            marked.foregroundColor = Color.accentColor
            marked.backgroundColor = Color.accentColor.opacity(0.14)
            out += marked

            rest = afterOpen[closeRange.upperBound...]
        }

        var tail = AttributedString(String(rest))
        tail.foregroundColor = Color.secondary
        out += tail
        return out
    }
}
