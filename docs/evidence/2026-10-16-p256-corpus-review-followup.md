# P-256 corpus review follow-up

Date: October 16, 2026. Initial reviewed candidate:
`ecf16933555d8538b9bac758350f20ea04d2d55f`.

## Review finding and change

Independent review found no actionable production-code defect in the candidate,
but identified nine mathematically invalid high-S Wycheproof cases that stopped
at Harc's input boundary instead of reaching cryptographic verification. The
original 89 invalid cases comprised 50 scalar-boundary rejections, 21 length
rejections, nine high-S rejections and nine verifier rejections. Those counts
must not be described as 89 cryptographic negative checks.

The corpus test now pins the nine IDs: **4, 21, 35, 205, 254, 256, 258, 259,
260**. For each case it explicitly requires `signatureNotLowS` for the original
wire input, then normalizes that public test vector internally and requires the
canonical low-S form to fail actual verification. The exact set of exercised IDs
must match all nine expected IDs, preventing silent loss of these checks.
Invalid signatures outside this named set retain their original boundary or
verification checks; arbitrary malformed scalars are not normalized.

The same test still checks all 173 valid corpus controls, including canonical
conversion of valid high-S generic ECDSA signatures and rejection of their
original high-S input. The five captured valid controls and their digest/signature
tamper checks remain active in the companion corpus test. Both original positive
assertions, RFC 6979, single-prehash, malformed-input and opposite-path tests are
unchanged. No production verifier, signing code, canonicality boundary, fixture,
dependency or gate changes are included in this follow-up.

## Focused validation

An exact copy of the updated test and unchanged candidate production sources ran
in the existing isolated SSD SwiftPM projection on M4 / macOS 26.6.2 (25G83),
Xcode 27.0 (27A266a): **11 tests / two suites passed**, 0.168 seconds test time,
4.03 seconds total. Two workers, a 300-second bound and a 6-GiB internal floor
were enforced; at least 11.5 GiB remained free. This is software/public-vector
validation, not physical iOS, Secure Enclave or persisted owner identity testing.

Updated corpus-test SHA-256:
`5283e019f782f4ff6c078c096df056e71b6b12b268ab290e44510bcbb855503f`.
Local log/receipt:
`/Volumes/MacMiniSDD/HarcBuilds/p256-equivalent-form-20261016/evidence/review-followup-focused-run.log`
and `.json`. Exact original assertions, production source and fixture bytes were
checked unchanged. `git diff --check` passed.

The prior candidate's
[CI 38988749517](https://github.com/jkrack/Harc/actions/runs/38988749517)
passed package, Mac app/helper and mobile simulator checks at `ecf1693`.
It does not replace exact new-head checks. Use the PR's current head, terminal CI
and independent re-review before deciding whether the coverage finding is closed.
No release-ready claim follows from the focused test or prior-head result.

## Limits retained

The original [candidate evidence](2026-10-16-p256-equivalent-form-candidate.md)
remains dated initial-candidate evidence. Both verification attempts still use
the same Apple provider; mathematical equivalence and finite test corpora do not
prove its unexplained discrepancy is exclusively false rejection. Broader macOS
and iOS matrices, physical production/Secure Enclave identities, signed Host/
receipt and pairing/session integration, hostile-input load, and existing codec/
physical/release qualification remain open. Mobile configuration CI does not run
this identity corpus on iOS. The declared real-model and opt-in pinned-TLS checks
remain separate. No merge, installation, recording, report to Apple or release
was performed by this follow-up.
