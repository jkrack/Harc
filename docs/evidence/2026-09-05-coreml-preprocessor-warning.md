# Core ML preprocessor load warning

Status: isolated, not resolved. This is a local diagnostic against the installed
Parakeet v2 model and macOS 26.5.2 (25F84) on Apple M4. No audio or prediction is
needed to reproduce it. No model files or production compute policy were changed.

A standalone probe calls `MLModel(contentsOf:configuration:)`, flushes output
around the load, and reads the input descriptions. All loads return successfully.

| Model | Compute policy | Zero-shape warning |
| --- | --- | --- |
| Preprocessor | CPU only | Yes, during load |
| Encoder | CPU and Neural Engine | No |
| Decoder | CPU and Neural Engine | No |
| JointDecision | CPU and Neural Engine | No |
| Silero VAD v6.2.1 | CPU and Neural Engine | No |

The preprocessor reports default input shapes `audio_length=[1]` and
`audio_signal=[1,1]`. The warning is:

```
E5RT encountered an STL exception. msg = Failed to PropagateInputTensorShapes: std::runtime_error during type inference for ios17.slice_by_index: zero shape error.
```

This proves the warning can arise during model loading independently of Harc's
VAD, chunking, audio buffers, or transcription inputs. It does not prove its
underlying cause, runtime fallback behavior, or harmlessness across all inputs.
The default shape is an observation, not a confirmed root cause.

Reproduction (the model path is local; do not upload recordings):

```sh
swiftc -j 2 -parse-as-library scripts/quality/CoreMLLoadProbe.swift -o /private/tmp/harc-coreml-load-probe
/private/tmp/harc-coreml-load-probe "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2/Preprocessor.mlmodelc" cpu
```

Evidence is retained under
`build/qualification/production-hardening-2026-09-05/coreml-load-probe/`:
per-model logs, the result matrix, OS/toolchain details, exact probe source/binary
hashes and preprocessor file hashes. The separate synthetic STT corpus passed
its fixed thresholds despite this warning. Its VAD-associated substitution is a
separate quality finding, not explained by the load-only reproduction.

Next investigation should target this compiled model/Core ML combination and
compare valid-input prediction behavior or an upstream corrected artifact. Do
not suppress diagnostics or change shipped compute policy merely to hide the
warning. No external issue or message has been posted.
