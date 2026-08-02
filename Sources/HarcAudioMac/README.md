# HarcAudioMac

macOS-specific microphone and ScreenCaptureKit system-audio adapters may move
here only after the host/mobile vertical slice is stable and focused extraction
tests preserve current behavior. `HarcAudio` remains authoritative until then.

Portable writing, mixing, levels, destinations, and recovery behavior become
shared only where both real platform implementations demonstrate the same
contract. Directory symmetry is not a reason to move working capture code.
