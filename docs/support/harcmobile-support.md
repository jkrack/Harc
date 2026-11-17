# Harc for iPhone support

Harc for iPhone is a private companion to the Harc Host running on a Mac you
control. It records locally, preserves a protected master while the Host is
offline, and transfers recordings only to the Host you adopt. The bundled
offline review sample works without an account or Host.

## Requirements

- An iPhone running iOS 26 or later
- Microphone permission for recording
- Harc for Mac for pairing, summaries, speaker names, and the canonical Library
- A compatible iPhone, supported current language and installed Apple speech
  model for optional on-device transcript previews
- Local Network permission for direct Host discovery
- Camera permission only when scanning a Host pairing code

Harc Remote is optional. It provides reachability when a direct connection is
unavailable, while the recording and Library connection remain encrypted between
the iPhone and adopted Host.

## Common questions

### My Host is offline. Can I still record?

Yes. Harc keeps a protected local master and queues it until the adopted Host is
available. Do not delete the app while recordings are waiting to transfer.

### Can I transcribe without my Mac?

On a compatible iPhone, Harc can create an on-device transcript preview after
saving a recording. Availability depends on the device and current language.
If the Apple speech model is missing, use **Download speech model** in the
transcript section. This separate download needs a connection; your recording
is not uploaded. Routine processing uses installed assets with no cloud
recognizer fallback.

Queued transcription resumes while Harc is open and not recording. If it fails,
your saved audio and transfer are unaffected; use **Retry on-device transcription**
when available. Older recordings are not bulk-transcribed automatically, but
you can request **Transcribe on this iPhone** for an individual local recording.

The preview does not replace the adopted Host's transcript or a user edit.
Speaker names and summaries still come from the Mac. A local preview is not a
Host receipt and does not authorize deletion of the protected recording.

### Why does a recording say Saved locally?

The recording is durable on the iPhone but has not yet received a verified
durable receipt from the adopted Host. Harc retains the local master until that
receipt arrives.

### Why does Harc request camera or Local Network access?

Camera access is used only to scan a short-lived pairing code. Local Network
access discovers and connects to the Host you approve. Recording remains a
separate, explicit action.

### Can the relay or developer read my recordings?

No. Recording and Library content stays encrypted through the optional relay,
and Harc's developer has no access to the iPhone or adopted Host library. See
the [HarcMobile privacy policy](../privacy/harc-mobile-privacy-policy.md).

## Contact support

Email [support@cloudarchitech.com](mailto:support@cloudarchitech.com).
Include the Harc version, iOS version, iPhone model, the visible status message,
and steps to reproduce. Do not attach private recordings or transcripts unless
you deliberately choose to share them.

Source-code defects and reproducible technical issues may also be filed through
[GitHub Issues](https://github.com/jkrack/Harc/issues). Public issues are visible
to everyone, so remove personal, recording, pairing, network, and security data.
