import AVFoundation

/// Whether this Mac actually has a microphone to record from.
///
/// Distinct from the Microphone *permission*, which is what the readiness row
/// used to report on its own. On a Mac mini — no built-in mic — permission is
/// granted and no input device exists, so the panel showed "Microphone ✓ ·
/// Mic + system audio" and "Capture ready" on a machine that cannot capture a
/// single sample. The failure only appeared later, as
/// `com.apple.coreaudio.avfaudio error -10868` from deep inside AVAudioEngine.
public enum AudioInputAvailability {
    /// True when the system reports at least one audio input device.
    public static var hasInputDevice: Bool {
        if AVCaptureDevice.default(for: .audio) != nil { return true }
        // `default(for:)` can be nil while devices exist but none is chosen as
        // the system default, so fall back to enumerating.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return !discovery.devices.isEmpty
    }
}
