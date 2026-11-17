import Foundation

/// Shared coordinate mapping for waveform and speaker playback surfaces.
enum PlaybackSeekPosition {
    /// Inverse of seek mapping. No marker is drawn before playable audio has
    /// loaded. Keep real subsecond durations rather than stretching them to 1s.
    static func x(seconds: Double, width: CGFloat, inset: CGFloat = 0, duration: Double) -> CGFloat? {
        guard seconds.isFinite, width.isFinite, inset.isFinite,
              duration.isFinite, duration > 0, width > 2 * max(0, inset) else { return nil }
        let padding = max(0, inset)
        let fraction = min(1, max(0, seconds / duration))
        return padding + CGFloat(fraction) * (width - 2 * padding)
    }

    static func seconds(x: CGFloat, width: CGFloat, inset: CGFloat = 0, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, inset.isFinite,
              duration.isFinite, duration > 0, width > 2 * max(0, inset) else { return 0 }
        let padding = max(0, inset)
        let fraction = min(1, max(0, (x - padding) / (width - 2 * padding)))
        return Double(fraction) * duration
    }
}
