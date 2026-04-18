import SwiftUI
import AppKit

/// Design tokens for the "Auditory Lens" design system.
/// Palette + typography + spacing + corner radii.
public enum HarcDesign {
    // MARK: Palette

    /// Primary action color — Tech-Lavender → Deep Cobalt base.
    public static let primary = Color(red: 0.0, green: 0x58/255.0, blue: 0xBB/255.0)
    public static let primaryContainer = Color(red: 0x6C/255.0, green: 0x9F/255.0, blue: 1.0)
    /// Accent/creative tint — Tertiary purple for AI-generated features.
    public static let tertiary = Color(red: 0x88/255.0, green: 0x3C/255.0, blue: 0x93/255.0)
    /// Error/danger color — reserved for destructive actions only.
    public static let error = Color(red: 0xB3/255.0, green: 0x1B/255.0, blue: 0x25/255.0)

    /// On-surface text — semantic NSColor labels so they adapt to light/dark appearance.
    public static let onSurface = Color(nsColor: .labelColor)
    public static let onSurfaceVariant = Color(nsColor: .secondaryLabelColor)
    public static let outlineVariant = Color(nsColor: .separatorColor)

    /// Primary gradient for hero actions (135-degree angle).
    public static let primaryGradient = LinearGradient(
        colors: [primary, primaryContainer],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Corner radii

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let full: CGFloat = 9999
    }

    // MARK: Spacing — base 4px grid

    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
    }

    // MARK: Typography

    public enum Font {
        /// Display — editorial hero, tight letter-spacing, bold.
        public static let displayMd = SwiftUI.Font.system(size: 28, weight: .bold, design: .default)
        /// Title — primary anchor for sections.
        public static let titleLg = SwiftUI.Font.system(size: 18, weight: .semibold, design: .default)
        public static let titleSm = SwiftUI.Font.system(size: 14, weight: .semibold, design: .default)
        /// Body — meeting transcripts, dense readable text.
        public static let bodyMd = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        public static let bodySm = SwiftUI.Font.system(size: 11, weight: .regular, design: .default)
        /// Label — all-caps metadata, technical pro-app feel.
        public static let labelMd = SwiftUI.Font.system(size: 11, weight: .medium, design: .default)
    }
}

public extension Color {
    /// Convenience on `Color` for design-system palette access.
    static let harcPrimary = HarcDesign.primary
    static let harcPrimaryContainer = HarcDesign.primaryContainer
    static let harcTertiary = HarcDesign.tertiary
    static let harcError = HarcDesign.error
    static let harcOnSurface = HarcDesign.onSurface
    static let harcOnSurfaceVariant = HarcDesign.onSurfaceVariant
    static let harcOutlineVariant = HarcDesign.outlineVariant
}
