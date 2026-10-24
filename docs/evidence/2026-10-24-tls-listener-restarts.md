# Bounded TLS listener restart regression

This is source-level diagnostic evidence, not sealed release, physical-phone,
TLS handshake, installed Host restart, or long-duration endurance qualification.
The checkout started at main `befd4e9fc4cfb1fccd7f0123e81e1785f44891f2`.
PR 145 preparation work and the physical codec/phone round-trip gates are separate.

## Reproduced fixture defect

On the Mac mini, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), a disposable
plaintext `NWListener(using: .tcp, on: .any)` produced:

```text
handler=false state=failed(POSIXErrorCode(rawValue: 22): Invalid argument)
handler=true state=ready
handler=true state=cancelled
```

The existing TLS test and its plaintext control both omitted
`newConnectionHandler`. Their matching EINVAL errors therefore did not establish
that the environment could not run listeners. The control's known-issue branch
returned before completing the advertised 50 TLS cycles.

## Change and validation

The test bridge now installs a connection handler before starting, cancels any
unexpected inbound connection, and requires **ready then cancelled** for success.
Each cycle has a five-second deadline covering both readiness and cancellation.
Listener failures, premature cancellation, missed callbacks and caller
cancellation throw. Queue-confined completion and cleanup prevent late or
duplicate callbacks from resuming the continuation again. There is no
known-issue/early-success fallback. Certificate count assertions remain after
every completed cycle, followed by an explicit 50-cycle count assertion.

`TMPDIR=<SSD temporary root> python3 -B scripts/qualify-tls-identity.py` passed
21 tests across three suites. The real TLS test printed:

```text
Harc certificate count: before=0, after=0; 50 listener cycles
```

Focused coverage includes real plaintext readiness/cancellation, late and
duplicate callbacks, cancellation before readiness, propagated EINVAL, missing
readiness/cancellation deadlines, and caller cancellation. Two additional
concurrent processes each completed 50 identity resolutions with certificate
count `0 -> 0`. The qualification script now includes the existing shared test
support target and identity fixture resources required by the current sources.

Repository smoke also passed: 130 aggregate script tests, protocol schema
checks, package manifest validation, and Xcode project generation.

The local run was performed during development, before the final commit; it is
not an exact release-artifact receipt. Raw probe and test logs are retained on
the SSD under `HarcBuilds/tls-listener-restarts-20261024/evidence/`.
Required full PR CI must be evaluated at the pushed head. This test starts and
cancels listeners; it does not connect a client or prove a TLS handshake, live
recording, phone projection, or prolonged Host availability. No production
transport policy or readiness gate is changed.
