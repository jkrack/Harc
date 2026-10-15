# P-256 verification qualification: blocked

Date: 2026-10-15. Source baseline: `c802dce6c8c638f0f7d95e8c0fc7c8cebbe58920`
(tree `f7e47ed593e52535be224b30076dd3937ccff69e`). This is synthetic
software-key evidence from the development Mac mini, not physical-phone,
relay deployment, sealed archive, or App Store qualification.

## Finding

A bounded software-key diagnostic reproduced rejection of a newly generated,
valid low-S P-256 signature on iteration 12. The captured public vector now has
a deterministic positive assertion in `P256SigningTests`. On this Mac it fails
without concurrency, networking, application state, or private credentials.
The standalone `scripts/reproduce-p256-verification.swift` uses only CryptoKit's
standard SHA-256 digest and public-key/signature initializers; it has no Harc
module or custom digest adapter dependency.

Environment: macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Apple Silicon.
CryptoKit rejects the fixed vector with both the original and reimported public
key, both Harc's precomputed digest and CryptoKit's standard SHA-256 digest,
and both raw and DER signature construction. Ten consecutive fixed-vector
checks agree. An ephemeral public SecKey also rejects it with OSStatus -67808,
“EC signature verification failed, no match.” No key was stored in Keychain.

OpenSSL 3.6.2 accepts the exact vector. Four independently captured failures
(iterations 12, 110, 272, 308) all pass OpenSSL 3 with the supplied prehash and
all fail its changed-digest and double-hash controls. A separate P-256 equation
check also accepts them. The system LibreSSL verifier rejects the first vector;
substituting the system `openssl` is therefore not an independent passing check.
This localizes the discrepancy to the Apple verification boundary; it does not
establish the precise underlying framework defect or justify replacing a
production verifier.

## Relation to the intermediate main CI failure

[CI 38738116849](https://github.com/jkrack/Harc/actions/runs/38738116849),
source `2443bec4ce8a21e6281ab94106e9d68fe1d4edbc`, failed the test
“remote relay endpoint bytes are bound into pairing admission” with
`.invalidSignature`. The final combined
[CI 38738216824](https://github.com/jkrack/Harc/actions/runs/38738216824)
passed on `c802dce6`, including that unchanged case, 1,611 package tests and
38 simulator tests. Identity production sources, protocol production sources,
and protocol tests have no diff between those two commits.

A bounded repeat of the exact existing admission test on current-main source
failed on iteration 98 with `.invalidSignature`. The production source and the
existing fixture/test were unchanged in this run. The failure occurred in
0.052 seconds after build completion; the loop stopped immediately. This is
additional failure evidence, not a successful rerun and not a fix. Historical
CI did not preserve the rejected signed bytes, so matching its exact signature
or proving identical root cause is not possible from that log alone.

A second diagnostic added logging only to the isolated test fixture at
`VerifiedHostTransportSetV1.decode`, then stopped on the next demonstrated
failure (iteration 519). Its exact rejected frame, signing prehash, public key,
and raw low-S signature are preserved in
[the public fixture evidence](2026-10-15-p256-verification-vectors.json).
OpenSSL 3 accepts that exact transport signature and rejects its changed-digest
and double-hash controls. The second fixed regression uses these captured
transport bytes. This confirms the current-source protocol failure crosses the
same verification boundary; the historical CI signature is still unavailable.

## Focused validation

The isolated source projection copies exact main `HarcDomain` and
`HarcIdentity` sources; the protocol projection additionally uses exact main
`HarcTransfer`, `HarcProtocol`, and generated wire schemas with cached package
checkouts. Native SwiftPM builds use `--jobs 2`, a 900-second process-group
limit, and a 6-GiB disk stop threshold (above the repository's 5-GiB floor).

- Captured-vector regressions: **FAIL**, two positive verification assertions.
- RFC 6979 vector / double-hash rejection control: **PASS**.
- High-S and malformed scalar rejection controls: **PASS**.
- Exact relay-admission bounded diagnostic: **FAIL**, iteration 98.
- OpenSSL 3 cross-check: **PASS**, five valid signatures and ten rejected
  changed/double-hashed digests.

No whole-tree green claim is made. Production app source is unchanged; current
main's earlier package, macOS app/helper, and mobile simulator CI remains
historical evidence, and cannot erase these demonstrated failures. This draft
retains the failing assertion and does not add retries, expected failures,
verification fallbacks, altered scalar rules, or a codec enablement.

## Reproduce the fixed vector

```sh
swift scripts/reproduce-p256-verification.swift
swift test --jobs 2 --filter 'captured.*SignatureInteroperability'
```

The public key is X9.63, the signature is raw `r || s`, and the message is
`harc-signature-diagnostic-12`. Their exact hex values are in the regression
and the standalone script. For an independent OpenSSL 3 check, encode the
public point as a prime256v1 SPKI and the signature as DER, then run:

```sh
openssl pkeyutl -verify -pubin -keyform DER -inkey public.der \
  -sigfile signature.der -in digest.bin -pkeyopt digest:sha256
```

Use OpenSSL 3 explicitly and confirm its version; the development Mac's
`/usr/bin/openssl` is the failing system implementation. `digest.bin` must
contain the 32-byte SHA-256 digest, not the message or a second hash.

## Launch consequence and next work

Treat deterministic verification disagreement as an open baseline blocker on
the affected platform before claiming new signed Host/receipt qualification.
Next: compare the saved public vector on another supported Mac/OS and the
named iOS roles, isolate the platform implementation, and resolve the cause
without weakening canonical signature validation. Tests on phones require a
separate authorized physical session; none ran here. No production fix or
completed Host/relay restart qualification is claimed by this change.

PR #106's bounded-runner/executor work is merged and is not repeated here.
Existing canonical-ingest tests already cover publication crash recovery,
on-disk reopen, exact lost-receipt replay, and duplicate-origin idempotency;
existing background ingest tests cover in-memory crash boundaries. Those are
not substitutes for composed on-disk background/relay restart or physical
sync evidence, and their completion is not newly claimed here.

App Store release remains **NO-GO**: the physical lossless codec matrix and
production codec selection, named-device C/T/P/H and two-network/revocation
acceptance, UI/accessibility/protection/reboot/upgrade acceptance, deployed
privacy/retention closeout, owner App Privacy/export compliance, sealed signed
archive, exact screenshots/reviewer flow, account metadata/agreements, and
upload/processing/submission checks remain open under the existing runbooks.
Omega is supplementary Pro hardware; it does not replace XR/iOS 18 or the
current non-Pro iPhone 17 matrix roles. TestFlight remains optional.
