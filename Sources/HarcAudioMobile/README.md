# HarcAudioMobile

iOS-specific `AVAudioSession`, microphone capture, interruption handling, route
handling, canonical PCM conversion, protected master writing, durable frame
checkpoints, repair, and discontinuities will live here.

The real-time callback only copies into a bounded handoff buffer. Compression,
hashing, file/database access, networking, and UI updates happen outside it.
Capture and transfer have independent state machines.

System-wide application or call audio capture is not part of this module's
contract.

Finalized WAV and capture metadata publication precedes outbox registration.
Launch recovery scans unregistered finalized metadata as well as active frame
checkpoints. It validates the producing identity, metadata invariants, canonical
WAV header, exact length, and PCM hash before returning a master to the app.
Registered origins are skipped so receipt-governed cleanup cannot resurrect audio.
Each invalid orphan is excluded and reported independently, with its files
preserved in place. Directory setup and enumeration failures still throw.
