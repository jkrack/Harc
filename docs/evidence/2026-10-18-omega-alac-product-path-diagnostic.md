# Omega CAF/ALAC product-path diagnostic

**Date:** 2026-10-18 (Pacific)

**Disposition:** Physical engineering pass for CAF/ALAC integrity and one
phone-to-Host durable receipt. This is not sealed release-candidate evidence.

## Scope

- Physical phone: Omega, iPhone 15 Pro Max (`iPhone16,2`), iOS 26.6.
- Development team: `63TNU5M7P4`.
- Repository base: `3afdccf`; the installed diagnostic app also contained the
  uncommitted physical-EOF encoder correction and an exact Debug-only launch
  argument enabling CAF/ALAC. The production compile condition remained off.
- No security-blocked recording was retried.
- Simulator results were not used for the physical claims below.

## Physical encoder regression

The focused physical tests passed on Omega:

- `HarcMobileALACPhysicalRegressionTests/testPhysicalEOFDoesNotRejectBitExactALAC`
- `HarcMobileUploadPreparationTests/testDebugCodecDiagnosticRequiresExactLaunchArgument`

Result bundle:
`/Volumes/MacMiniSDD/HarcBuilds/mobile-transfer-diagnostic-3afdccf/Logs/Test/Test-HarcMobile-2026.10.18_21-03-10--0700.xcresult`

The regression encodes and decodes 20,000 canonical frames on the physical
phone. It verifies the exact decoded byte count and SHA-256. The diagnosed bug
was an extra one-frame read at exact CAF/ALAC EOF: physical iOS throws a generic
Objective-C EOF error even after the file reports the expected frame length and
all canonical bytes have already matched.

## Real phone-to-Host receipt

The existing protected local capture below traversed the production upload,
canonical ingest, receipt signing, response validation, and durable client
receipt path:

| Field | Value |
| --- | --- |
| Origin recording | `4a88f890-d7d8-464f-b9c0-57600939067e` |
| Upload | `d770f19e-5e83-4e6c-8d46-e9014ad17872` |
| Host canonical recording | `8c968f9d-7692-4a0d-bae5-af0e7fef6e31` |
| Canonical frames | 44,800 |
| Canonical PCM SHA-256 (base64) | `rQ6jsAgmhnO5GOUyYg9MxFRmG6VAkfIeElwNg2y8hJ4=` |
| Receipt object SHA-256 (hex) | `1910C5B70A7A4E3839CD86CB5200579FF73606646A7D4EE6465277BD9661342B` |
| Exact receipt bytes | 647 |

The Host's bound finalized capture, chunk descriptor, and phone's finalized
capture all contain the same canonical PCM SHA-256 and frame count. The Host
row is `committed` / `processing`. The phone has one committed outbox and one
verified receipt with the same receipt object SHA-256 and byte count.

The read-only phone snapshot is `/tmp/harc-mobile-audit.9QCTsB`. It retained 13
finalized captures, 119 capture files, and zero cleanup intents. Therefore the
local protected master was not cleaned before receipt verification. The audit
script returned nonzero only after collecting the complete mobile snapshot,
when its final live-Host aggregate query encountered a transient SQLite lock;
the Host rows above were then read independently with SQLite read-only mode.

## Additional findings

- The Host's four-active-upload ceiling was reached exactly after one existing
  upload and three newly accepted uploads. The Host mapped that capacity state
  to gRPC `invalidArgument`, producing the misleading client text “The request
  is malformed.” The source correction maps this Host work ceiling to
  `resourceExhausted`; its focused Host and gRPC mapper suites pass.
- A second accepted recording reached a signed Host receipt but remained in a
  recoverable publication checkpoint at `receiptPrepared`, so the phone reported
  `missingReceiptAfterCommit`. That recovery-path defect remains open and is not
  hidden by the successful first receipt.
- Two durable background ACKs and the verified foreground recovery above prove
  useful parts of the path, but the diagnostic app was not built from a clean,
  pushed candidate commit. Land the fixes, enable the selected codec through the
  reviewed production setting, and repeat the receipt path on that exact build
  before calling the release candidate qualified.

