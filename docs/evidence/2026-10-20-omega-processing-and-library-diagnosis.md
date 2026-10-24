# Omega processing and phone Library reconciliation

## Scope and result

Read-only reconciliation on October 20 started from main
`08849bc0a8e02ad48f530e2e376e1cbbb9e3ef67`. The native status, receipt-repair,
and design tasks were idle when inspected. Their checkouts and uncommitted edits
were preserved. No apps were installed, launched, stopped or recorded into;
no cache, grant, receipt, file identity or security state was changed.

The previously receipted 91,200-frame Omega capture has **two separate blockers**:
current Host processing cannot accept its persisted file binding, and the phone
Library cache predates the recording. Missing phone metadata does not demonstrate
that Host transcription failed, or that completion of transcription would refresh
the phone automatically.

## Host processing boundary

The canonical Host Library row remains `failedRecoverable` with
`host.processing_retry`; projection is `pending`, with no transcript artifacts.
Its publication journal remains `processing`, with no publication error recorded.
These states describe different stages and must not be collapsed into one result.

Metadata comparison found the same device, inode, owner, mode, link count and byte
length as the persisted canonical identity. The file change time differs by about
21 seconds. There is no receipt-repair or artifact-binding event for this upload.
An independent executable compiled the exact, unmodified current-main
`HostCanonicalArtifactIdentity.swift` and `StoreError.swift`. Its read-only
`validatePathBinding` call on the existing path rejected the persisted identity
with `canonicalArtifactIdentityMismatch`, without reading the audio contents.
The same files have no source changes between installed Host source `1f75648`
and the inspected main commit.

This proves a **current recovery blocker**, not the cause of the original failure.
The row's first failure update was at 21:54:51 UTC on October 19, while the observed
file change time is 21:54:56 UTC. The source of the metadata change is unknown.
Current Harc stderr is `/dev/null`, and retained diagnostics do not authenticate
the original exception. Existing daemon errors are not tied to this capture.
No claim is made that admission, daemon startup or transcription caused that first
failure. Thermal, Low Power Mode, capture and load deferrals remain legitimate.

Ordinary processing and launch recovery must continue rejecting this binding.
Any recovery must use the existing explicit, owner-authorized validation path;
this investigation neither performed nor authorized repair. It did not weaken
signed manifest, receipt, content or path checks.

## Phone Library boundary

Omega is a physical iPhone 15 Pro Max (`iPhone16,2`), connected separately from the
iPhone Simulator. The installed production bundle `com.harc.HarcMobile` reports
0.14.17 (72). A separate Tide diagnostic bundle is also installed; its UI tests
are not evidence for the production bundle's Library state. The installed Mac
reports 0.14.17 (72), source `1f75648`, rather than current main.

A new copy of only the production phone's Library-cache directory shows 195 rows,
no row for this capture, and cursor 312. Its last successful persisted refresh is
October 19 at 04:23:29 UTC. The matching Host Library publishes this capture at
cursor 333 and its failure state at 335; its current cursor is 339. The matching
Library identity rules out comparing unrelated libraries. A read-only phone file
listing still finds the capture sidecar and 182,444-byte WAV master. No phone
audio or capture contents were copied or read by this investigation.

`RecordingStore.anchoredLibrarySnapshot()` includes nondeleted recordings before
transcription is ready. The focused integration test added here verifies that a
failed-processing, pending-projection recording appears in the path-free snapshot
and change feed with its canonical audio metadata. Thus Host processing repair and
phone metadata refresh are separate next steps. The failing phone refresh stage
or RPC status has not been observed; the stale cursor alone cannot identify it.
Use the existing stage-specific `HarcMobileLibraryCoordinator` diagnostics during
an explicitly observed refresh, preserving the existing cache and pairing.

## Independent validation and limits

- Six standalone identity checks passed: unchanged and fresh synthetic identities
  accepted; metadata drift, replaced inode and symlink bindings rejected; the real
  persisted binding rejected using metadata only. Synthetic changes affected only
  an owned temporary fixture.
- Selected current-main Store sources and two existing integration suites were
  compiled in an isolated SSD package with the locally retained GRDB dependency.
  Together with the new visibility regression, all ten tests passed with zero
  failures or skips. This selected-source harness is not the full repository
  package, Mac app, device or release validation.
- Evidence, copied validation sources, manifests and the phone metadata snapshot
  are retained locally under
  `/Volumes/MacMiniSDD/HarcBuilds/phone-library-projection-20261020/evidence`.
  Private databases and product metadata are not committed to the repository.

The on-device listing also exposes mode `0600` and the MobileBackup exclusion
marker on the master and sidecar. It does not expose the exact iOS Data Protection
class or prove locked/reboot access behavior; those physical gates remain open. No clean current-main app pair, sealed archive,
end-to-end phone Library round trip, physical codec/reliability matrix, TLS
endurance, two-network or App Store qualification was completed. The outstanding
owner clarification on endurance and quantitative gates is unchanged. No Sparkle
release, notarization upload, submission or issue #105 work was performed.
