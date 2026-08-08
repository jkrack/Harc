# Runtime Roles and Pairing Runbook

This runbook covers the local-network Host, Mac Client, and iPhone client
implementation on `codex/host-client-mobile`. It does not replace the physical
device release gates in the normative specification.

## Prepare the Host computer

1. Open Harc Settings, choose **General > This Mac > Host**, confirm the role
   change, and restart Harc.
2. Keep Harc running. Closing its windows is safe; choosing Quit or sleeping
   the computer makes the Host unavailable and clients queue locally.
3. Choose **Pair a Device…** from the File menu or status-item menu.
4. Select the requested device kind and scopes. Create a fresh two-minute
   pairing ticket for each client.

The Host may be a Mac mini, Mac Studio, iMac, or laptop. Its persistent
authority identity is independent of its computer name, IP address, Bonjour
name, and rotatable TLS leaf.

## Pair an iPhone

1. In HarcMobile, open pairing and tap **Scan Host Pairing Code**.
2. Scan the QR displayed by the Host.
3. Confirm that the four security words and device label match on both devices.
4. Approve the exact requested scopes locally on the Host.
5. Wait for HarcMobile to show the adopted Host, then record normally. Capture
   and recovery do not wait for the Host; queued work resumes when it returns.

Reject the claim and create a new ticket if any word, label, or requested scope
differs. Possessing the QR ticket alone never grants access.

## Pair a secondary Mac

1. On the secondary Mac, choose **General > This Mac > Client**, confirm, and
   restart Harc.
2. On the Host, choose **Pair a Device… > Mac client** and create the short-lived
   pairing QR code.
3. For Macs in the same room, select **Scan Host Code** on the Client. For a Mac
   elsewhere, select **Save Invite…** on the Host and deliberately transfer the
   resulting `.harcpair` file to the Client, then double-click it or choose
   **Open Pairing Invite…**. The invitation contains the same one-time bearer
   secret as the QR, expires after two minutes, and is protected as a
   current-user-only file. Harc does not upload or relay it. Email, messaging,
   cloud drives, and Universal Clipboard can place the secret outside Harc's
   private trust boundary, so use only a channel you intentionally trust and
   delete any transferred copy after pairing.
4. The Client displays the Host address, authority fingerprint, and expiry
   before making a connection. Confirm **Connect to This Host** only if those
   details match the Host you intended to adopt.
5. Compare the four security words and device label on both Macs, then approve
   the exact scopes on the Host.
6. Use **Host Library…** for the scoped canonical Library. The Client's earlier
   library remains separately available as **On This Mac**; Harc never merges,
   moves, or uploads it implicitly.

New Client-mode recordings capture and transcribe locally with `harc-stt` while
lossless upload proceeds concurrently. The Host either accepts a compatible,
coverage-complete signed processing artifact or visibly schedules its own
processing. A durable signed receipt, not transcript completion, governs client
master cleanup.

## Work-Mac audio policy

Client mode separates permission to download Host audio from permission to
retain it:

| Preference key | Default | Effect |
| --- | --- | --- |
| `harc.client.hostAudioDownloadEnabled` | `true` | Allows verified canonical Host audio to be fetched for playback. |
| `harc.client.hostAudioRetentionEnabled` | `false` | Keeps fetched Host audio after playback. It is forced off when downloads are disabled. |

The UI exposes these as **Allow Host audio downloads** and **Keep downloaded
Host audio**. Disabling either policy clears the protected audio cache. Local
capture and local transcription are unaffected.

For local testing, the keys live in the `com.harc.Harc` defaults domain. An MDM
profile can force either key as a managed preference; Harc disables the
corresponding control and applies the effective policy at Client startup and on
preference changes.

## Diagnostic CLI

Use [`harcctl`](host-pairing-cli.md) to validate discovery, pairing,
authenticated reconnect, compressed fixture upload, receipt verification, and
processing status without standing up a second authority.

## Release boundary

Before calling the mobile or secondary-Mac flow release-ready, complete the
open gates in the
[implementation status](../evidence/2026-08-03-host-client-mobile-implementation-status.md):
the bounded clean Mac/iOS builds, the C1/C2/T1/T2 physical-device matrix, and a
real two-Mac end-to-end run.
