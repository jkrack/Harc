# Codec spike — iOS simulator diagnostic

**Date:** 2026-08-02

**Status:** Diagnostic only; not release-decision evidence

## Environment

- Simulator: iPhone 17 / `iPhone18,3`
- Runtime: iOS 26.5 build 23F77
- Source state: dirty PR 3 working tree based on
  `e868a34ef50f9ca71fe40f087836162f5bd8f13b`
- Mode: quick matrix, five independently decodable 60-second chunks per codec
- Evidence schema: 2, with run-wide resident high-water and thermal observation
- Monotonic runtime: 1.411 seconds (accelerated; deliberately non-qualifying)
- Canonical format: 16,000 Hz, mono, signed Int16 little-endian PCM

## Result

Both native Apple encoding paths completed every chunk and decoded bit-exactly
to the original canonical PCM SHA-256.

| Candidate | Chunks | Bit exact | p95 encode | Max encode | Encoded total | Peak incremental resident memory |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| CAF + ALAC | 5/5 | Yes | 72.00 ms | 72.00 ms | 8,545,454 bytes | 12,926,976 bytes |
| FLAC | 5/5 | Yes | 32.02 ms | 32.02 ms | 8,508,445 bytes | 12,926,976 bytes |

There were no codec failures and no serious or critical thermal state reported
by the run-wide observer. The shared peak-memory value is intentionally
conservative for this two-codec diagnostic. For each of the ten trials, the
decoded PCM hash exactly equaled the source PCM hash.

## Interpretation

This run proves that the checked-in harness builds and executes end to end and
that the current iOS SDK exposes working CAF+ALAC and FLAC encoders/decoders for
Harc's canonical format. It does **not** measure physical CPU, memory pressure,
energy, thermals, background behavior, or oldest-device queue depth. It must not
freeze the release codec/container.

The normative PR 3 gate still requires the three-hour, 180-chunk real-time run
on the named oldest-supported and current physical iPhones with an exact clean
build commit recorded. A qualifying run now also requires at least 10,800
seconds of monotonic elapsed time, so neither accelerated execution nor a
wall-clock adjustment can produce a false pass.
