# Mobile immutable-intent replay and queue progress

Reuse the entire durable Begin intent when a recording retries. The app
previously re-encoded its chunks and derived a new frozen profile from the latest
negotiation, then reused only the old upload ID. An additive Host capability
changed the profile digest and made the store reject an otherwise compatible
retry with `uploadAlreadyExistsWithDifferentFacts`.

The app now checks the durable intent before invoking the encoder. A replay loads
its original upload ID, profile, descriptors, and file paths. New local attempts
still use the current negotiated profile. Both paths require current Host upload
authorization, and the unchanged foreground uploader validates the current
session, exact Begin replay, compatible capabilities, and artifact bindings.
The codec gate remains closed.

The app queue also excludes work bound to another Host's trust tuple, both when
collecting pending work and before processing each job. A per-recording failure
does not stop unrelated eligible work in that pass. A set of attempted origins
prevents a wake or completion callback from repeatedly requeueing the same failed
recording within one pass. Pairing, codec, and cancellation stops still retain
remaining work for a later retry. No recording is retargeted or removed.

Baseline validation began on main
`496e4d1bab8017025f2e969a1d051d9d2c2fb903`. The existing app composition and queue
behavior were mechanically extracted into socket-free seams, preserving their
fresh-profile/fresh-chunk reconstruction and stop-after-first-error behavior.
Four regression tests failed: the reconstructed plan drifted after additive
negotiation, fresh providers ran for a stored intent, old Host-A work delayed
Host-B work, and a recoverable first-job failure stranded the next job.

Five corrected app-composition tests pass in a headless macOS harness. They
exercise the real durable store and foreground uploader through an RPC fake that
drops Begin responses. The replay produces identical Begin bytes twice, retains
the original durable intent, and never invokes fresh profile/chunk providers.
An injected encoder runs once for a new recording and zero times for its retry.
Missing required capabilities, malformed authorization, and incompatible encoding
still fail before another Begin RPC. Two independently signed synthetic Host
namespaces prove that the queue skips A and reaches B's process callback in the
same pass while both local masters remain unchanged. A synthetic terminal outcome
is used for B; this is not evidence of a physical Host commit. Further tests cover
one attempt per origin and a true global stop.

The harness copies the app helper into its ClientTransport target and omits
only the app-test `HarcMobile` import; the test already imports ClientTransport
with test access for deliberately synthetic session fixtures. Test bodies remain
unchanged, and production initializer visibility is unchanged. This allows local execution without a simulator. The real app
module and its hosted tests still require Xcode compilation/CI. The mobile
configuration CI script now explicitly selects the new test class.

Main advanced to `8b0c74f0bfc585731b377fcd84beadb6f9f60dc4` with PR117 during
validation. The branch fast-forwarded cleanly. Integrated validation passed all five
composition XCTests and 65 store/background tests. Generic iOS app/test
build-for-testing passed with signing disabled and two workers. The hosted test
fixtures use the existing test-only transport import for synthetic session
construction; no production initializer was exposed. Hosted iOS execution awaits
CI because the local simulator runtime is unavailable. Parsing, shell syntax,
and diff checks passed, with at least 12.15 GiB free during final validation.

Diagnostics are under `/tmp/harc-sync-evidence`, including
`upload-composition-baseline.log`, `upload-preparation-baseline.swift`, focused
and integrated test logs, and watchdog receipts. All content is synthetic and
all files are temporary. No phone action, production transfer, grant restoration,
security setting, or release action ran. Physical re-pairing, codec, two-network,
and direct/relay lifecycle qualification remain open.
