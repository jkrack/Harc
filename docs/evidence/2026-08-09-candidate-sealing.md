# Harc relay and mobile candidate sealing

**Date:** 2026-08-09

**Implementation commit:**
`bcaba87283d1d9c80315e4e432310da8a04602e6`

## Decision

The relay hardening and HarcMobile 0.14.1 (56) implementation source is sealed
at the commit above. The current-source validation passed; the product remains
no-go for iPhone App Store submission and broad Secondary-Mac Client release
until the explicitly open physical, upload, support-contact, and
account-owner gates pass.

## Candidate validation

- `npm run check` passed the production privacy guard, both generated Worker
  type checks, TypeScript, four Vitest files with 17 unit tests, one Durable
  Object integration test, and production/observer dry bundles.
- `swift test --jobs 2` passed 1,541 Swift Testing cases in 259 suites and 123
  XCTest cases. Four real-model XCTest cases were skipped by their declared
  opt-in contract.
- A signed run on Omega, iPhone 15 Pro Max (`iPhone16,2`) on iOS 26.6, passed
  all 24 hosted app tests and all 6 UI tests without failures or skips. The
  post-annotation UI rerun also passed 6/6.
- The iPhone 17 iOS 26.5 simulator passed all 24 hosted app tests and all three
  applicable UI tests, with exactly three physical-only UI tests skipped.
- The existing macOS `Harc` arm64 Debug target built successfully with two
  workers, preserving compilation evidence for the desktop application rather
  than relying on Swift package tests alone.
- Shell syntax, Node script syntax, the high-signal secret scan, and
  `git diff --check` passed before sealing.

## Preserved Xcode results

- Physical complete run:
  `Test-HarcMobile-2026.08.09_14-26-15--0700.xcresult`
- Physical UI warning-cleanup rerun:
  `Test-HarcMobile-2026.08.09_14-28-42--0700.xcresult`
- Simulator complete run:
  `Test-HarcMobile-2026.08.09_14-30-37--0700.xcresult`

## Still open

- Replace `ACCOUNT_HOLDER_MONITORED_SUPPORT_EMAIL` with a monitored address.
- Capture the five exact-build App Store screenshots, then upload and reconcile
  the validated distribution export.
- Complete the named oldest/current non-Pro iPhone codec and C/T/P/H matrix;
  Omega is additional Pro-device evidence and replaces neither named cell.
- Complete the real Secondary-Mac Client acceptance flow.
- Complete physical two-network/direct-route/visible-revocation relay evidence
  and confirm historical sampled-record expiry on or after 2026-08-16.
