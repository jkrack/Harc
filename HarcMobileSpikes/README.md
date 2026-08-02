# HarcMobileSpikes

This directory is reserved for the non-shipping, signed iOS 18 physical-device
harness used to decide the lossless codec before host ingest and to validate
background TLS/gRPC behavior before the production mobile transport freezes.

It becomes an Xcode target only in PR 3, is never distributed, and is folded
into or removed by PR 7. Spike results are recorded as dated evidence; spike
code does not silently become product code without the production tests and
boundaries in the implementation specification.
