# P-256 verification fixtures

`ecdsa_secp256r1_sha256_p1363_test.json` is an unmodified copy from
C2SP/Wycheproof revision `7a325932231bd7a724c791c8b0d65ea4d6d2f435`:
https://github.com/C2SP/wycheproof/blob/7a325932231bd7a724c791c8b0d65ea4d6d2f435/testvectors_v1/ecdsa_secp256r1_sha256_p1363_test.json

SHA-256: `c60de693930e386c3a5472d08081623ef8504decc54b38ac01ec6b2a2575c986`. Apache-2.0 license retained in
`WYCHEPROOF-LICENSE`. These are test-only resources, not an application dependency.

`harc-captured-p256.json` is an unchanged copy of Harc's public synthetic fixture
record at `docs/evidence/2026-10-15-p256-verification-vectors.json`. It contains
five previously independently verified signatures rejected by the affected Apple
low-S verification path, including the captured transport signature. No user key
or recording data is included.
