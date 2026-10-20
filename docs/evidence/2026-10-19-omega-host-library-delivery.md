# Omega to Host Library delivery

## Result

The user's October 19 10:19 a.m. Pacific recording on Omega reached the resident
Mac Host and appeared in its Library. The Library row and detail pane display
`Recorded on iPhone`, the device's existing Host pairing label. Labels resolve
the recording's persisted origin device ID, independently of the storage Host.
Legacy rows without an origin ID explicitly report unavailable provenance.

The final installed Mac and iPhone builds are 0.14.17 (72), source
`f01d4b3818581d2c51c5a209d755ccfadeeb034c`. The phone is Omega, iPhone 15 Pro Max,
iOS 26.6. The Mac candidate is Developer ID signed, notarized, stapled, and passed
`verify-release.sh`. No public Sparkle release was published.

## Verification

- The phone persisted a verified signed receipt; its exact bytes and object
  digest match the Host publication journal.
- Independent streaming SHA-256 verification of the actual canonical Host WAV
  matched both the finalized phone capture and receipt.
- Frame count: 91,200 mono Int16 frames at 16 kHz (5.7 seconds).
- The Host Library database contains the same canonical recording and origin.
- The installed Mac Library visibly renders the recording, waveform, and origin
  label in both the row and detail pane.
- The protected phone master remains present; no cleanup intent was created.
- Ten phone recordings had verified receipts at the audit checkpoint.

## Transfer repair

Recreated background URLSession tasks reused numbers belonging to historical
completed task mappings. Retained mapping checks rejected these collisions,
leaving uploads incomplete and consuming Host admission capacity. Scheduling now
cancels unresumed tasks whose identifiers are already recorded and allocates a
fresh identifier, bounded to 32 attempts. Historical mappings and signed-object
checks remain unchanged. Exhaustion remains retryable.

All 17 `HarcBackgroundURLSessionUploadClientV1Tests` passed, including the new
historical-identifier regression and existing ACK, request binding, and late
callback isolation tests. Mac Release and physical-device iPhone Debug builds
succeeded. The prior physical codec tests remain separate evidence; this delivery
check does not claim completion of the full physical release matrix.

## Limits

The verified recording's Host transcription is still pending. The phone's cached
Host Library projection did not contain it at the snapshot checkpoint; that is
separate from the verified Mac Host Library entry. Other historical recovery and
security-blocked items remain unresolved and were not discarded or bypassed.
No claim of two-network, endurance, power-loss, or App Store qualification is made.

Local evidence is retained under `/private/tmp/harc-omega-origin-success`,
`/private/tmp/harc-omega-origin-receipts-verified.json`,
`/private/tmp/harc-origin-retry-tests.log`, and
`/private/tmp/harc-omega-origin-release-verified.log`.
