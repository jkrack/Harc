# Protocol fixtures

This directory contains three different frozen inputs; none is generated during
tests.

## Pairing SAS dictionary

`harc-sas-words-v1.txt` is the exact 2,048-entry English word ordering published
with [BIP 39](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt),
retrieved on 2026-08-02. Harc uses it only as a human-comparison dictionary for
the pairing short-authentication string. `Package.swift` copies these exact
bytes into the `HarcProtocol` resource bundle; production loading verifies the
frozen hash before deriving a phrase.

The protocol hash is:

```text
2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda
```

Do not reorder, normalize, translate, or regenerate the file. The normative
bit-to-index mapping is in the implementation specification.

## Exact-wire golden corpus

`harc-wire-v1-golden.txt` is the reviewed V1 interoperability corpus. It freezes
all nine signed-object registry frames and object IDs, host transport, pairing
ticket and URI, pairing/SAS proof, session proof, `HARCAB1`, `HARCPB1`, and
the exact negotiated-capability payload and SHA-256 plus
current/additive-unknown protobuf bytes. Signatures were emitted once; tests
verify the checked-in exact values and must not regenerate their own expected
bytes.

## Schema checksum inventory

`harc-protocol-sources-v1.sha256` pins the seven `.proto` sources and generator
configuration consumed by `scripts/check-harc-protocol-schemas.sh`. Update it
only with deliberate review of the corresponding V1 contract change.
