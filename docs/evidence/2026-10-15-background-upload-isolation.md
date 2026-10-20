# Background upload task isolation

Retire stale system-task mappings before they can change replacement upload
state. A late completion previously compared its old request against the batch's
new capability, rejected the credential difference, and security-blocked the new
batch and recording. Late task-failure persistence also poisoned retries that
reused the credential.
Separately, an unfinished task for a forgotten or revoked Host threw through the
whole reconciliation transaction and blocked healthy work for the current Host.

The fix gives historical mappings a terminal `retired` state. Capability refresh
retires old inactive mappings in the credential transaction. A replacement task
also retires inactive mappings for its immutable batch and requires that no other
task is active for that batch. Retired identities cannot be reused for resume.
Only active mappings can validate a completion or report an ACK; failure
persistence independently enforces the same boundary. A completed batch's verified
ACK and an active callback's security block remain durable.

Before transport reads jobs, and again during reconciliation, the store retires
mappings whose trust or upload lifecycle no longer authorizes them. It retains
the immutable batch, credentials, files, and mapping history. Observed retired
system tasks are returned for cancellation and are never matched or rescheduled.
Current authorized tasks continue through reconciliation. Known authorization
failures are isolated; database corruption and I/O errors still surface and roll
back the transaction. No grant is restored by this path.

Validation used main `0ef6054cfcc099eda1e70c053eee687f71456ff5` and synthetic
fixtures in temporary directories. No phone action or production transfer ran.

- Against unchanged main source, the four regression tests failed with seven
  issues: stale completion rejected the refreshed request, stale failures
  security-blocked replacement work with both reused and refreshed credentials,
  forgotten-Host reconciliation threw `inactiveTrustTuple`, and revoked-grant
  reconciliation threw `nonauthorizingGrantStatus("revoked")`.
- With the fix, all 65 focused tests in seven suites passed. This includes every
  ClientStore suite and the background URLSession suite, active signed-ACK and
  response rejection, durable security blocks, revoked grants, transaction
  rollback on corrupt database facts, and local-master byte retention.
- The focused macOS harness copied the exact source for Domain, Identity,
  Transfer, ProtocolWire, Protocol, ClientStore, RemoteTransport, and
  ClientTransport into a temporary package with the repository's selected target
  definitions and cached pinned dependencies. It ran all ClientStore tests and
  the background URLSession tests, not the full repository package suite.
- Generic iOS `HarcMobile` app/test build-for-testing passed with signing disabled
  and two workers. Swift parsing and `git diff --check` passed. Both build and
  focused-test watchdogs observed at least 11.02 GiB free.

Local diagnostics are under `/tmp/harc-sync-evidence`: `background-baseline.log`,
`background-isolation-tests.log`, their watchdog receipts, and
`background-source-manifest.json`. The copied-source manifest verifies the exact
source/fixture files against this branch. These are diagnostic files, not release
qualification artifacts.

The immutable-intent retry finding remains open. Exact-source physical codec,
phone transfer, and direct/relay lifecycle qualification remain open. This change
preserves the closed codec gate and does not modify pairing, credentials, security
settings, or the original dirty checkout.
