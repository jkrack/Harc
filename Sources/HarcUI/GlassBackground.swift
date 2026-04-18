import SwiftUI

/// Glass-morphism background modifier. Matches the design system's "Glass & Gradient"
/// rule: translucent Material with rounded corners and ambient shadow.
public struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat
    let material: Material

    public init(cornerRadius: CGFloat = HarcDesign.Radius.lg, material: Material = .regularMaterial) {
        self.cornerRadius = cornerRadius
        self.material = material
    }

    public func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 32, x: 0, y: 8)
    }
}

public extension View {
    /// Applies the glass background treatment (translucent material + rounded corners + ambient shadow).
    func glassBackground(cornerRadius: CGFloat = HarcDesign.Radius.lg) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
