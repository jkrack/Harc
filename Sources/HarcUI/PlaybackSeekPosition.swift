import Foundation

/// Shared coordinate mapping for waveform and speaker playback surfaces.
enum PlaybackSeekPosition {
    static func seconds(x: CGFloat, width: CGFloat, inset: CGFloat = 0, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, inset.isFinite,
              duration.isFinite, duration > 0, width > 2 * max(0, inset) else { return 0 }
        let padding = max(0, inset)
        let fraction = min(1, max(0, (x - padding) / (width - 2 * padding)))
        return Double(fraction) * duration
    }
}
