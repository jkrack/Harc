# P-256 combined-main blocker and correction assessment

Date: October 16, 2026. Reviewed main:
`3f9f090ae4bd1266651ceb94f2a553f10d1de08a`.

## Decision

No supported upstream correction or validated Harc implementation fix was
identified within the current dependencies and environment. Keep the two
positive assertions active and defer installation preparation from this main
baseline. Do not substitute the passing #122 branch checks for combined-main
validation. Installed builds and the codec/upload gates remain unchanged.

## Current evidence

[Main CI 38901509843](https://github.com/jkrack/Harc/actions/runs/38901509843)
completed with **failure** at the exact reviewed SHA on arm64 macOS 26.6.2
(25G83), Xcode 26.6 (17F113). Package compilation and the 31-test strict-executor
lane passed. The full Swift Testing run reported 1,613 tests / 270 suites and
exactly two issues:

- `capturedLowSSignatureInteroperability`, `P256SigningTests.swift:61`.
- `capturedTransportSignatureInteroperability`, `P256SigningTests.swift:88`.

These are the unchanged positive low-S signature assertions merged by
[PR #120](https://github.com/jkrack/Harc/pull/120). Its merge adds tests,
public-vector evidence, a reproducer and planning prose; it changes no production
verifier. The 124 XCTest cases had zero failures and four declared skips. Mac
app/helper and external-construction checks were skipped after the package
failure; mobile configuration was skipped because it depends on that job.

The [diagnostic artifact](https://github.com/jkrack/Harc/actions/runs/38901509843/artifacts/12047093588)
was retained locally and verified against GitHub's SHA-256:
`fc6096b75c3ee65d7308b99f4e087fda06a7e71c7938e0b814fe16ed788b8a2f`
(89,128 bytes). Local receipt:
`/tmp/harc-sync-evidence/main-38901509843-verified-summary.json`.

The [original evidence](2026-10-15-p256-verification-qualification.md) and
[public vectors](2026-10-15-p256-verification-vectors.json) remain intact. The
later investigation recorded in #120 narrows the demonstrated failure to
synthetic small-scalar fixture keys. General production-key applicability and
the identity of the shipped implementation remain unproved. Existing local
evidence also records SecKey rejection, standard message/prehash rejection,
raw/DER agreement, independent normalization checks and OpenSSL 3 acceptance
with changed-digest/double-hash rejection controls. Those are prior results;
they were not rerun against installed apps in this follow-up.

## Correction assessment

On this check, Apple's published corecrypto main and the latest history entry
for `ccec_full_add.c` both resolve to
`9612a959abb6eac0aac3ee6a7245c46365c9d81b` (2026/05 release). No later correction
appeared in that file's public history. A bounded repository issue search found
no matching ECDSA/ccec/doubling issue; that does not establish the absence of a
private Apple report or an untested OS correction.

The independently written mathematical model suggests a narrow upstream repair:
when subtraction makes the two effective points equal, double that effective
point. The [published exceptional branch](https://github.com/apple/corecrypto/blob/9612a959abb6eac0aac3ee6a7245c46365c9d81b/ccec/src/ccec_full_add.c#L52-L65)
instead doubles the un-negated table input. For the five saved scalar-15 vectors,
the model reaches `+14G - (-14G)`: correct doubling yields `+28G`, while the
modeled branch yields `-28G` and fails verification. The corresponding
[joint-multiplication caller](https://github.com/apple/corecrypto/blob/9612a959abb6eac0aac3ee6a7245c46365c9d81b/ccec/src/ccec_twin_mult.c#L86-L102)
and recoding were already pinned in #120. This is an inference matching the
observed behavior, not identification or execution of the OS framework's code.

A fresh dependency-free Python model run reproduced all five saved low/high
results exactly. Copies and output are in
`/tmp/harc-p256-followup-20261016/`; SHA-256 checks confirmed the original model,
vectors and result files were unchanged. High-S variants are diagnostic model
controls only, never a proposed accepted Harc input. No native build was started
with the internal disk below the repository floor.

Harc's adapter directly imports CryptoKit and verifies a typed single SHA-256
prehash after strict key and scalar validation. No adapter defect was identified
that explains failures also reproduced without Harc. Re-encoding DER, changing
the digest API, substituting SecKey or updating Swift Crypto is not a validated
repair. Harc pins Swift Crypto 4.5.0 at
`1b6b2e274e85105bfa155183145a1dcfd63331f1`; its
[implementation documentation](https://github.com/apple/swift-crypto/blob/1b6b2e274e85105bfa155183145a1dcfd63331f1/README.md#implementation)
states that its normal Apple-platform API delegates to CryptoKit. Bundling a
different provider would be a separate implementation and dependency decision.
The [corecrypto publication](https://github.com/apple/corecrypto#licensing-and-contributions)
is for security research and verification under its evaluation-only license;
it is not a supported redistributable Harc patch.

## Security implications and owner decision

The established symptom is rejection of valid synthetic signatures. This does
not demonstrate acceptance of forged signatures, key disclosure, or a failed
production phone identity. Conversely, bounded random-key success does not prove
all production keys safe. A verifier replacement could change accepted inputs,
malformed-point handling, scalar bounds, low-S enforcement, prehash semantics
and behavior across OSes. Passing only the two saved vectors is insufficient.

Recommended owner decision: keep this baseline blocked; authorize a report to
Apple through its [documented security-reporting route](https://support.apple.com/en-us/102549)
and arrange separate cross-OS/framework validation of the unchanged public
reproducer. No report was sent. If a provider replacement is required sooner,
approve a separate security-reviewed design and dependency scope before code.
Any candidate must retain these assertions and the single-prehash, tamper,
malformed-key/scalar and high-S rejection controls, then pass the required
package, app and mobile checks on exact source identities. Physical and codec
qualification remain separate requirements even after a verifier correction.

The native task `Plan Harc iOS port` was idle when checked, and no compiler/test
process was active. This follow-up uses a separate main-based documentation
worktree; the native task's dirty checkout and all installed builds were left
untouched. The external APFS SSD `/Volumes/MacMiniSDD` has about 2 TB free for
future build outputs, but that does not remove the need for internal OS/temp
headroom or resolve the signature blocker.
