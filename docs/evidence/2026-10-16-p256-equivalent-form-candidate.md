# P-256 equivalent-form verification candidate

Date: October 16, 2026. Base main:
`3f9f090ae4bd1266651ceb94f2a553f10d1de08a`.

## Candidate and security boundary

The two retained captured-vector assertions now pass in focused testing with
this candidate. The production change is confined to `P256X963PublicKey`'s
verification method. No signing algorithm, wire bytes, key material, authority,
prehash, codec policy or dependency provider changes.

Harc first validates its existing strict X9.63 key and 64-byte raw **low-S**
signature types. Verification still tries CryptoKit with that signature and the
existing exact SHA-256 prehash. If rejected, it checks `(r, n - s)` internally
with the same public key and prehash. This is one additional bounded
cryptographic check, not new signing attempts or an unbounded retry.

ECDSA verification computes `R = (z/s)G + (r/s)Q`. Replacing `s` with `n-s`
negates both coefficients, so `R` becomes `-R` and its x-coordinate is unchanged;
point-at-infinity rejection is also unchanged. Both representations therefore
have the same mathematical validity. Incoming high-S signatures remain rejected
by `P256RawSignature`; the alternate never crosses Harc's wire/storage boundary.
No invalid signature may be accepted without CryptoKit verification.

On the affected Apple platform, some valid vectors fail only in one form.
Both paths are necessary: using only the alternate loses other valid vectors.
The original-path counterexample is pinned in `P256SigningTests`. This candidate
does not identify the shipped Apple implementation or assert an official Apple
fix; the exceptional-branch model remains a hypothesis in the earlier evidence.

The existing two failing positive assertions are unchanged. New persistent tests
cover all five captured signatures with altered-digest, double-hash and signature
tamper controls, and the pinned raw-signature Wycheproof corpus. Its generic
ECDSA valid high-S cases are converted only for positive mathematical tests;
original high-S inputs are separately required to fail Harc's constructor.
Invalid corpus inputs are never normalized before testing rejection.

## Validation actually run

Environment: M4 Mac mini, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a).
An isolated SSD SwiftPM projection copied exact `HarcDomain` / `HarcIdentity`
sources and both candidate test files. No Keychain or physical-device tests ran.
All commands used two workers, a 300-second process-group bound and a 6-GiB
internal disk floor; at least 12.2 GiB remained free.

- **PASS:** 11 focused tests / two suites, including both original assertions,
  RFC 6979/single-prehash, malformed key/scalar and high-S rejection, the original
  verification-path counterexample, all five captures, and all 262 Wycheproof
  vectors (173 valid, 89 invalid).
- **PASS:** actual patched-verifier diagnostic: 10,418 canonical positive and
  41,761 negative checks, zero mismatches. It recovered 20 baseline false
  rejections, including all five captures. An alternate-only verifier rejected
  13 other valid samples. These bounded software-key results are not a proof
  covering every key or OS. Random sample counts may vary between runs.
- **PASS:** independent OpenSSL 3.6.2 verified the 20 recovered public vectors,
  13 opposite-path samples and the fixed opposite-path regression: 68 low/high
  positive checks accepted; 68 changed-digest/double-hash checks rejected.
- **Expected failure control:** restoring unmodified main's verification source
  produced seven captured-vector issues (the two original assertions and five
  added corpus expectations). Restoring exact candidate source passed all 11
  tests again. This control did not alter repository source or hide a failure.
- **PASS:** official fixture bytes and copied source/test hashes matched;
  `xcodegen generate` and `git diff --check` passed.

Wycheproof source:
[`7a325932231bd7a724c791c8b0d65ea4d6d2f435`](https://github.com/C2SP/wycheproof/blob/7a325932231bd7a724c791c8b0d65ea4d6d2f435/testvectors_v1/ecdsa_secp256r1_sha256_p1363_test.json),
SHA-256 `c60de693930e386c3a5472d08081623ef8504decc54b38ac01ec6b2a2575c986`.
The unmodified test-only file and Apache-2.0 license are retained in
`Tests/HarcIdentityTests/Fixtures/`.

Local evidence: `/Volumes/MacMiniSDD/HarcBuilds/p256-equivalent-form-20261016/`.
The `evidence/` directory contains `candidate-focused-run.*`,
`candidate-matrix-run.*`, `candidate-matrix-result.json`,
`negative-control-run.*`, `candidate-restored-run.*`,
`independent-openssl-results.json` and source manifests. Matrix result SHA-256:
`8c33197f21830014934152a121084a5581bd04eb9feaf8a1b8b8d79a2413f309`. Initial diagnostic compiler errors are retained separately;
they are not successful test evidence. No prior diagnostic evidence was removed.

Reproduce the persistent regression suite from a normal checkout:

```sh
swift test --jobs 2 --filter 'P256SigningTests|P256VerificationCorpusTests'
```

Exact candidate file SHA-256 values from the tested projection:

| File | SHA-256 |
| --- | --- |
| `Sources/HarcIdentity/P256Signing.swift` | `1c54167916801f144f980f884f0379d3b50e1a8bf3c351edeb80b74e45116f16` |
| `Tests/HarcIdentityTests/P256SigningTests.swift` | `4aebcce7f85abfca45098d2d927594c7c780243eb135c46620ed8015d84c3ad1` |
| `Tests/HarcIdentityTests/P256VerificationCorpusTests.swift` | `486b1dc148e146e1df47e878ae3ccb19bcf8c23814aea1bc1d8ebf32552d51dc` |

## Remaining review and qualification

This is a security-sensitive compatibility candidate for review, not release
clearance. Full repository package, Mac app/helper and mobile CI must run at the
published head. Broader supported OS and physical iOS validation remain open;
local software-key success does not qualify production phone identities or signed
Host/receipt end-to-end behavior. Rejection now costs at most one additional
CryptoKit verification, which reviewers should consider for hostile-input load.

Main still contains the demonstrated blocker until a reviewed correction is
merged and validated. Codec and physical-transfer gates remain closed. No
installation, app launch, recording, public release, external Apple report,
credential/trust/permission change or App Store action occurred in this work.
