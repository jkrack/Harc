# HarcDomain

Portable, capability-neutral Harc values will live here: stable public IDs,
origin identity, revisions, change cursors, tombstones, capture discontinuities,
processing/projection states, and compare-and-swap results.

The module does not import protobuf, GRDB, Keychain, networking, or UI. Existing
`HarcCore` remains authoritative for current shared types; values move or bridge
only through focused compatibility tests.
