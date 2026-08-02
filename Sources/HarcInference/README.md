# HarcInference

The reusable in-process FluidAudio speech pipeline may live here after the
host/mobile vertical slice is stable and a measured use case justifies the
extraction from `HarcSTT`.

V1 host and desktop Client mode keep the existing `harc-stt` daemon. Future
supported mobile devices may use an in-process pipeline behind capability
negotiation, but mobile inference is not a release dependency.
