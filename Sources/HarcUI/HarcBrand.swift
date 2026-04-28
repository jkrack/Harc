import SwiftUI

/// The entire brand sliver. Three concerns: recording red, app-icon gradient,
/// and the menu-bar bars motif (which lives in MenuBarBarsIcon).
///
/// Everything else uses system primitives — Color.accentColor, Color.primary/.secondary,
/// system materials, system fonts. Do NOT add tokens here; if you need one, use system.
public enum HarcBrand {
    /// Recording / "live" red. Drives the menu-bar dot, the recording-state pill,
    /// and any chrome that signals "we are recording right now."
    public static let live = Color(red: 0xF0/255.0, green: 0x55/255.0, blue: 0x4D/255.0)

    /// Brand gradient. App icon, About panel only. Do not use as control fill.
    public static let gradient = LinearGradient(
        colors: [
            Color(red: 0x70/255.0, green: 0xA3/255.0, blue: 0xFF/255.0),
            Color(red: 0x33/255.0, green: 0x5C/255.0, blue: 0xE0/255.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
