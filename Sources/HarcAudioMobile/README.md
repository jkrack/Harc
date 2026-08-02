# HarcAudioMobile

iOS-specific `AVAudioSession`, microphone capture, interruption handling, route
handling, canonical PCM conversion, protected master writing, durable frame
checkpoints, repair, and discontinuities will live here.

The real-time callback only copies into a bounded handoff buffer. Compression,
hashing, file/database access, networking, and UI updates happen outside it.
Capture and transfer have independent state machines.

System-wide application or call audio capture is not part of this module's
contract.
