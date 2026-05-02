import SwiftUI

/// Local palette for the fluid-water waveform viz. Deliberately NOT in
/// HarcBrand — the brand sliver stays minimal (recording red + app
/// gradient). These three colors only exist to render the live and
/// static waveforms; if you find yourself reaching for them elsewhere,
/// that's a sign the palette needs to graduate.
public enum WavePalette {
    /// Center of the gradient — deep blue, sits on the horizontal axis.
    public static let center = Color(red: 0x1B/255.0, green: 0x4F/255.0, blue: 0x8C/255.0)

    /// Edge of the gradient — soft cyan, marks the wave peaks.
    public static let edge = Color(red: 0x5C/255.0, green: 0xD2/255.0, blue: 0xFF/255.0)

    /// Highlight stroke on the upper wave layer — light cyan, like light
    /// catching the water surface.
    public static let stroke = Color(red: 0x9C/255.0, green: 0xE2/255.0, blue: 0xFF/255.0)
}
