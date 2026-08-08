# Private Mac Pairing Invitation Validation

Date: 2026-08-07

## Outcome

Harc now supports pairing a secondary Mac that cannot see the Host QR code and
does not share its clipboard. The Host can explicitly export the exact
short-lived canonical pairing ticket as a `.harcpair` file. Harc does not
upload, relay, synchronize, or otherwise choose a transport for that file.

The receiving Client validates the complete ticket before network use and
shows the Host route, authority fingerprint, and expiry before the user can
connect. The existing four-word comparison and local Host approval remain
mandatory. Ticket consumption, cancellation, and the original two-minute
expiry are unchanged.

## Security boundary

- The invitation is the same one-time bearer secret as the QR, not a new
  pairing or identity protocol.
- The exported file is canonical ASCII, at most 1,400 bytes, and written with
  current-user-only `0600` permissions. A permission failure removes the
  just-written file and fails closed.
- Client file reads require a bounded regular file and use `O_NOFOLLOW`; a
  symlink, oversized file, non-file URL, noncanonical URI, or expired ticket is
  rejected before connecting.
- Harc never automatically writes or shares the secret. Save, Share, Copy, or
  moving the file through email, messaging, a cloud drive, or Universal
  Clipboard is an explicit user-directed export outside Harc's trust boundary.
- Opening a `.harcpair` document or `harc-pair://` URL is accepted only in
  Client mode. The ticket is queued only in memory while Client bootstrap
  finishes and is never logged.

## Validation

| Gate | Result |
| --- | --- |
| Canonical invitation codec | `PairingInvitationFileV1Tests` passed 2/2, including exact byte round trip plus whitespace, non-ASCII, oversize, and expiry rejection. |
| macOS document boundary | `HarcPairingInvitationDocumentTests` passed 2/2, covering symlink, oversize, and non-file rejection. |
| Transfer regression | Focused `swift test --jobs 2` passed 58 tests across invitation, durable outbox, foreground outbox, HARCAB1 background client, background listener, and recording-transfer gRPC suites. |
| macOS application build | Bounded `xcodebuild ... -jobs 2 build` exited 0 after compiling the app and embedding `harc-stt` and `harc-mcp`. |
| LaunchServices registration | Built Info.plist contains the `harc-pair` URL scheme, `.harcpair` document type, and `com.harc.pairing-invitation` exported UTType. |
| Physical iPhone configuration | `HarcMobileConfigurationTests` passed 12/12 with zero failures or skips on the connected iPhone 15 Pro Max running iOS 26.6. |
| Source hygiene | `git diff --check` passed. |

The raw Debug product's third-party Sparkle framework does not pass standalone
deep verification after Xcode's Debug copy/thinning step. This is not accepted
as a distributable artifact. The release pipeline re-signs Sparkle's nested
components and the complete app, then performs deep verification, notarization,
stapling, DMG verification, and Sparkle publication.

## Open hardware gate

Create a fresh Mac-client invitation on the real Host, transfer it deliberately
to the secondary Mac while both are reachable on the same local or private
network, open it before the two-minute expiry, compare the four words, approve
the exact scopes, and confirm the paired device identity appears on the Host.
Then record on the Client and verify local processing plus durable Host transfer
without merging the Client's earlier On This Mac library.
