# iPhone 15 Pro Max quick codec smoke

Date: 2026-08-04

This is a physical-device diagnostic only. It proves that both candidate codecs
execute successfully on this phone, but it does not satisfy the three-hour,
fresh-process, two-device release matrix in
[`mobile-physical-qualification.md`](../operations/mobile-physical-qualification.md).

## Sealed build and device

- Source commit: `b400a558f14c74a5a76cff7c6b4c1b04f4c702fb`
- Signing team: `63TNU5M7P4`
- Bundle: `com.harc.HarcMobileSpikes`
- Version/build: `0.13.0 (45)`
- Device: Omega, iPhone 15 Pro Max (`iPhone16,2`)
- OS: iOS 26.0 (`23A340`)
- Interface: phone; physical iOS device; not Simulator or iOS-on-Mac
- Report UUID: `92EADBD2-7BCA-497A-9548-30B3B10A681B`
- Process launch UUID: `9CBAC0FE-8839-4494-878D-57CE95EBFA86`
- Raw report: [`2026-08-04-omega-quick-codec-spike.json`](2026-08-04-omega-quick-codec-spike.json)

## Results

| Candidate | Chunks | Bit-exact | Failures | p95 encode | Max encode | Max queue | Incremental RSS | Encoded bytes |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CAF + ALAC | 5/5 | Yes | 0 | 438.708 ms | 438.708 ms | 1 | 22,986,752 B | 8,545,454 B |
| FLAC | 5/5 | Yes | 0 | 36.667 ms | 36.667 ms | 1 | 22,986,752 B | 8,508,445 B |

Memory and thermal measurements were available for every trial. Neither
candidate observed a serious or critical thermal state. All ten decoded PCM
hashes matched their canonical input hashes.

## Interpretation

The quick smoke passed its diagnostic purpose: both codecs are functional and
bit-exact on `iPhone16,2`, with queue depth below the frozen ceiling and no
reported failures. FLAC encoded this synthetic quick fixture substantially
faster and produced 37,009 fewer bytes across the five chunks. This short,
accelerated run is not representative of three-hour memory or thermal behavior
and cannot select or enable the production codec.

The next gate on this phone is two separate fresh-process, three-hour runs: one
CAF + ALAC run and one FLAC run. A second named iPhone is still required to
complete the four-cell qualification matrix.
