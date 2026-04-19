import SwiftUI

/// Small capsule chip used to render a single tag.
public struct TagChip: View {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(HarcDesign.Font.labelMd)
            .foregroundStyle(Color.harcOnSurfaceVariant)
            .padding(.horizontal, HarcDesign.Space.xs)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.harcOutlineVariant.opacity(0.25))
            )
    }
}
