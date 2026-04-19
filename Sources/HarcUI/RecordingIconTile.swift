import SwiftUI

/// Rounded-square icon tile used in popover/library rows. Filled with a soft
/// tint of the accent color; foreground symbol is the accent itself.
public struct RecordingIconTile: View {
    public let systemImage: String
    public let accent: Color
    public let size: CGFloat

    public init(systemImage: String, accent: Color = .harcPrimary, size: CGFloat = 36) {
        self.systemImage = systemImage
        self.accent = accent
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: HarcDesign.Radius.sm, style: .continuous)
            .fill(accent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(accent)
            )
    }
}
