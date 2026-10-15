# Recovery transfer-domain admission

Keep transfer-domain validation inside the orphan's admission boundary. Main
`496e4d1bab8017025f2e969a1d051d9d2c2fb903` accepted metadata with independently
valid but reversed discontinuities, then failed in `FinalizedCapture` construction
after the scanner returned. That exception could still block app bootstrap.

The scanner now accepts an additional pure admission validator, and the app uses
its existing transfer-domain conversion there before admitting a master. Invalid
orphans remain excluded and reported with their files preserved. Database
insertion remains outside the per-artifact catch, so persistence failures still
surface. This also covers future transfer-domain validation changes without
duplicating the transfer invariants in the audio writer.

A focused diagnostic used exact main audio source and the same real transfer
conversion outside quarantine. Its regression failed with
`invalidOrdering(FinalizedCapture.discontinuities)`, as expected. With admission
inside quarantine, all 13 focused durability tests passed using exact copied
Domain, Identity, Transfer, and AudioMobile source in a temporary package. The new
test recovers a healthy master, reports the reversed-discontinuity orphan, and
checks that its metadata and WAV bytes remain unchanged.

The existing mixed-orphan app integration test now includes the same reversed
discontinuities alongside a healthy registered master and valid orphan. It checks
local Library availability, an idle capture coordinator, rejection reporting,
unchanged artifact bytes, and idempotence. App-test execution awaits CI because
this Mac has no available iOS simulator runtime.

Generic iOS app/test build-for-testing passed with signing disabled and two
workers. Swift parsing and diff checks passed.

Local diagnostics are under `/tmp/harc-sync-evidence`, including
`baseline-domain-admission.log`, `domain-admission-tests.log`, and watchdog
receipts. These tests use synthetic temporary files and do not qualify a physical
codec or transfer. No phone, production transfer, trust, credential, or release
action occurred.
