import SwiftUI
import AppKit

// DEPRECATED: this entire file is scheduled for deletion in Phase 7 cleanup.
// Do not add new references. Use HarcBrand for the brand sliver and
// Color.primary / .secondary / .accentColor / system materials elsewhere.

/// Harc design tokens — dark-first, Apple Silicon utility-app aesthetic.
///
/// Five surface stops (elevation = tone shift, not shadow), four ink levels,
/// one accent kept distinct from the row-selection fill, mono for numeric/file
/// content, six named type roles, an 8-stop spacing scale.
public enum HarcDesign {

    // MARK: Surfaces — elevation by tone shift

    public static let surface0 = Color(red: 0x0A/255.0, green: 0x0C/255.0, blue: 0x0F/255.0) // app bg
    public static let surface1 = Color(red: 0x10/255.0, green: 0x14/255.0, blue: 0x1A/255.0) // sidebar / rail / tray body
    public static let surface2 = Color(red: 0x16/255.0, green: 0x1B/255.0, blue: 0x22/255.0) // main / card
    public static let surface3 = Color(red: 0x1D/255.0, green: 0x24/255.0, blue: 0x2D/255.0) // hover / raised control
    public static let surface4 = Color(red: 0x25/255.0, green: 0x2E/255.0, blue: 0x39/255.0) // pressed / strong control

    // MARK: Borders

    public static let borderSubtle = Color(red: 0x1C/255.0, green: 0x23/255.0, blue: 0x2B/255.0)
    public static let borderStrong = Color(red: 0x2A/255.0, green: 0x33/255.0, blue: 0x3E/255.0)

    // MARK: Ink — 4 roles

    public static let inkPrimary    = Color(red: 0xE8/255.0, green: 0xEC/255.0, blue: 0xF1/255.0)
    public static let inkSecondary  = Color(red: 0x9A/255.0, green: 0xA4/255.0, blue: 0xB1/255.0)
    public static let inkTertiary   = Color(red: 0x6B/255.0, green: 0x73/255.0, blue: 0x80/255.0)
    public static let inkQuaternary = Color(red: 0x4A/255.0, green: 0x51/255.0, blue: 0x5B/255.0)

    // MARK: Accent + selection (deliberately different — Principle 04)

    /// Interaction, play, link. Tuned to read macOS-native without being literal system blue.
    public static let accent      = Color(red: 0x4E/255.0, green: 0x8C/255.0, blue: 0xFF/255.0)
    public static let accentHover = Color(red: 0x70/255.0, green: 0xA3/255.0, blue: 0xFF/255.0)
    public static let accentSoft  = Color(red: 0x4E/255.0, green: 0x8C/255.0, blue: 0xFF/255.0).opacity(0.16)

    /// Selection is a muted slate — accent only appears as a 3px leading edge.
    public static let selection     = Color(red: 0x2C/255.0, green: 0x3A/255.0, blue: 0x52/255.0)
    public static let selectionEdge = accent

    // MARK: Semantic

    public static let success = Color(red: 0x4F/255.0, green: 0xC3/255.0, blue: 0x82/255.0)
    public static let warning = Color(red: 0xE3/255.0, green: 0xB7/255.0, blue: 0x4D/255.0)
    public static let danger  = Color(red: 0xE5/255.0, green: 0x57/255.0, blue: 0x57/255.0)
    public static let live    = Color(red: 0xF0/255.0, green: 0x55/255.0, blue: 0x4D/255.0)

    // MARK: Tag chip — low-chroma blue tint

    public static let chipBg  = accent.opacity(0.12)
    public static let chipInk = Color(red: 0xC9/255.0, green: 0xD2/255.0, blue: 0xE3/255.0)

    // MARK: Type scale — 6 named roles

    public enum Font {
        // legacy names kept for backwards-compat with existing call sites
        public static let displayMd = SwiftUI.Font.system(size: 28, weight: .semibold, design: .default)
        public static let titleLg   = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        public static let titleSm   = SwiftUI.Font.system(size: 13, weight: .medium,  design: .default)
        public static let bodyMd    = SwiftUI.Font.system(size: 13, weight: .regular, design: .default)
        public static let bodySm    = SwiftUI.Font.system(size: 12, weight: .regular, design: .default)
        public static let labelMd   = SwiftUI.Font.system(size: 11, weight: .medium,  design: .default)

        // new system roles
        public static let display  = SwiftUI.Font.system(size: 28, weight: .semibold, design: .default)
        public static let title    = SwiftUI.Font.system(size: 17, weight: .semibold, design: .default)
        public static let subtitle = SwiftUI.Font.system(size: 15, weight: .semibold, design: .default)
        public static let body     = SwiftUI.Font.system(size: 13, weight: .regular,  design: .default)
        public static let meta     = SwiftUI.Font.system(size: 12, weight: .regular,  design: .default)
        public static let label    = SwiftUI.Font.system(size: 11, weight: .medium,   design: .default)

        /// Mono for timestamps, durations, file names, counts.
        public static let mono     = SwiftUI.Font.system(size: 12, weight: .regular,  design: .monospaced)
        public static let monoMd   = SwiftUI.Font.system(size: 13, weight: .regular,  design: .monospaced)
        public static let monoXs   = SwiftUI.Font.system(size: 10.5, weight: .medium, design: .monospaced)
    }

    // MARK: Spacing — 4-based, 8 stops

    public enum Space {
        public static let xxs: CGFloat = 4   // legacy alias of s2
        public static let xs:  CGFloat = 8   // legacy alias of s3
        public static let sm:  CGFloat = 12  // legacy alias of s4
        public static let md:  CGFloat = 16  // legacy alias of s5
        public static let lg:  CGFloat = 24  // legacy alias of s6
        public static let xl:  CGFloat = 32  // legacy alias of s7

        public static let s1: CGFloat = 2
        public static let s2: CGFloat = 4
        public static let s3: CGFloat = 8
        public static let s4: CGFloat = 12
        public static let s5: CGFloat = 16
        public static let s6: CGFloat = 24
        public static let s7: CGFloat = 32
        public static let s8: CGFloat = 48
    }

    // MARK: Radii

    public enum Radius {
        public static let sm:   CGFloat = 4   // pills, tags, kbd
        public static let md:   CGFloat = 6   // buttons, inputs
        public static let lg:   CGFloat = 8   // cards, menus
        public static let xl:   CGFloat = 12  // tray, modal
        public static let full: CGFloat = 9999
    }

    // MARK: Layout

    public enum Layout {
        public static let rowHeightCompact: CGFloat = 36
        public static let rowHeightCozy:    CGFloat = 44
        public static let rowHeightComfy:   CGFloat = 54
        public static let railWidth:        CGFloat = 340
        public static let sidebarWidth:     CGFloat = 220
    }

    // MARK: Brand gradient (used by app icon and hero marks)

    public static let primaryGradient = LinearGradient(
        colors: [
            Color(red: 0x70/255.0, green: 0xA3/255.0, blue: 0xFF/255.0),
            Color(red: 0x33/255.0, green: 0x5C/255.0, blue: 0xE0/255.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Backwards-compat shims (kept so other views still compile)

    public static let primary           = accent
    public static let primaryContainer  = accentHover
    public static let tertiary          = Color(red: 0x88/255.0, green: 0x3C/255.0, blue: 0x93/255.0)
    public static let error             = danger
    public static let onSurface         = inkPrimary
    public static let onSurfaceVariant  = inkSecondary
    public static let outlineVariant    = borderStrong
}

public extension Color {
    // legacy aliases — keep working
    static let harcPrimary           = HarcDesign.primary
    static let harcPrimaryContainer  = HarcDesign.primaryContainer
    static let harcTertiary          = HarcDesign.tertiary
    static let harcError             = HarcDesign.error
    static let harcOnSurface         = HarcDesign.onSurface
    static let harcOnSurfaceVariant  = HarcDesign.onSurfaceVariant
    static let harcOutlineVariant    = HarcDesign.outlineVariant

    // new system aliases
    static let harcSurface0      = HarcDesign.surface0
    static let harcSurface1      = HarcDesign.surface1
    static let harcSurface2      = HarcDesign.surface2
    static let harcSurface3      = HarcDesign.surface3
    static let harcSurface4      = HarcDesign.surface4
    static let harcBorderSubtle  = HarcDesign.borderSubtle
    static let harcBorderStrong  = HarcDesign.borderStrong
    static let harcInkPrimary    = HarcDesign.inkPrimary
    static let harcInkSecondary  = HarcDesign.inkSecondary
    static let harcInkTertiary   = HarcDesign.inkTertiary
    static let harcInkQuaternary = HarcDesign.inkQuaternary
    static let harcAccent        = HarcDesign.accent
    static let harcAccentHover   = HarcDesign.accentHover
    static let harcAccentSoft    = HarcDesign.accentSoft
    static let harcSelection     = HarcDesign.selection
    static let harcSelectionEdge = HarcDesign.selectionEdge
    static let harcChipBg        = HarcDesign.chipBg
    static let harcChipInk       = HarcDesign.chipInk
    static let harcLive          = HarcDesign.live
}
