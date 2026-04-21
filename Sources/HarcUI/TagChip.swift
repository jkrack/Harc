import SwiftUI

/// Small pill chip for a single tag — low-chroma blue tint per design system.
public struct TagChip: View {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.harcChipInk)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.harcChipBg))
    }
}

/// Compact "+N" overflow chip — shown after the inline tags when more exist.
public struct TagOverflowChip: View {
    public let count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        Text("+\(count)")
            .font(HarcDesign.Font.monoXs)
            .foregroundStyle(Color.harcInkTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }
}

/// Render a tag list with a hard cap and a "+N" overflow chip — keeps rows
/// at any density from collapsing when a recording has many participants.
public struct TagsRow: View {
    public let tags: [String]
    public let maxInline: Int

    public init(tags: [String], maxInline: Int = 2) {
        self.tags = tags
        self.maxInline = maxInline
    }

    public var body: some View {
        if tags.isEmpty {
            Text("—")
                .font(HarcDesign.Font.mono)
                .foregroundStyle(Color.harcInkQuaternary)
        } else {
            let shown = Array(tags.prefix(maxInline))
            let extra = tags.count - shown.count
            HStack(spacing: 4) {
                ForEach(shown, id: \.self) { TagChip($0) }
                if extra > 0 {
                    TagOverflowChip(count: extra)
                        .help(tags.dropFirst(maxInline).joined(separator: ", "))
                }
            }
        }
    }
}
