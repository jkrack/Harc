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
        !AudioInputDeviceCatalog.availableDevices().isEmpty
    }

    /// Explicit selections must still exist. System-default selection is ready
    /// only when macOS currently exposes a default input route.
    public static func hasInputDevice(for selection: MicrophoneSelection) -> Bool {
        AudioInputDeviceCatalog.resolvedDevice(for: selection) != nil
    }
}
