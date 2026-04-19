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
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            RecordingIconTile(
                systemImage: hit.recording.pinned ? "pin.fill" : "waveform",
                accent: hit.recording.pinned ? .harcTertiary : .harcPrimary,
                size: 32
            )
            VStack(alignment: .leading, spacing: HarcDesign.Space.xxs) {
                HStack(spacing: HarcDesign.Space.xs) {
                    Text(hit.recording.displayTitle)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    Spacer()
                    Text(RelativeTimeFormatter.format(hit.recording.startedAt))
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Text(TranscriptHitRow.highlight(hit.snippet))
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HarcDesign.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }

    /// Convert a snippet containing literal "<mark>…</mark>" spans into an
    /// AttributedString where matched tokens get HarcDesign.primary tint on
    /// a translucent primary-container background. Pure string walk — no HTML.
    public static func highlight(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(snippet)
        let open: Substring = "<mark>"
        let close: Substring = "</mark>"

        while let openRange = rest.range(of: open) {
            var plain = AttributedString(String(rest[..<openRange.lowerBound]))
            plain.foregroundColor = .harcOnSurfaceVariant
            out += plain

            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                var tail = AttributedString(String(afterOpen))
                tail.foregroundColor = .harcOnSurfaceVariant
                out += tail
                return out
            }

            var marked = AttributedString(String(afterOpen[..<closeRange.lowerBound]))
            marked.foregroundColor = .harcPrimary
            marked.backgroundColor = Color.harcPrimary.opacity(0.14)
            out += marked

            rest = afterOpen[closeRange.upperBound...]
        }

        var tail = AttributedString(String(rest))
        tail.foregroundColor = .harcOnSurfaceVariant
        out += tail
        return out
    }
}
