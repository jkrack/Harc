# HarcIdentity

Host and device identity primitives live here: strict P-256 X9.63 public keys,
single-prehash raw low-S signatures, stable key-derived IDs, installation-key
lifecycle, transport-neutral grant/registry models, scope policy, and signature
verification.

Production installation identity selection preserves an existing identity,
otherwise prefers a noninteractive Secure Enclave P-256 key whose opaque
same-device reference is stored in Keychain. Unsupported hardware and simulators
use a non-synchronizing, after-first-unlock, this-device-only Keychain software
fallback. Neither adapter exposes private-key material.

The installation device identity exists before first capture and before pairing;
pairing registers that stable key rather than creating it.

The module owns validated grant claims and registry decisions, not their PR4
protobuf encoding or signed-envelope bytes. It also does not own command
envelopes, recording manifests, receipts, network reachability, or application
UI.
