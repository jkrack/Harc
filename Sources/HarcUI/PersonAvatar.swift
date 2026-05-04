import SwiftUI

/// Colored circle with the Person's initials. Color is hash-derived from
/// the display name so it's stable per Person without storing anything.
public struct PersonAvatar: View {
    let displayName: String
    var size: CGFloat = 22

    public init(displayName: String, size: CGFloat = 22) {
        self.displayName = displayName
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Text(initials)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    private var color: Color {
        let hash = abs(displayName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.7)
    }
}
