# HarcIdentity

Host and device identities, Keychain-backed key abstractions, stable key-derived
IDs, signed grants and revocations, canonical signing bytes, and signature
verification will live here.

The installation device identity exists before first capture and before pairing;
pairing registers that stable key rather than creating it.

The module owns identity primitives, not protobuf command envelopes, recording
manifests, receipts, network reachability, policy state, or application UI.
