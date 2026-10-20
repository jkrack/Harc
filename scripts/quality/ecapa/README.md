# Native ECAPA diagnostic

This is an experimental evaluation tool, not Harc's selected production backend.
It runs the converted ECAPA embedding network through Core ML using native Swift
16 kHz mono audio loading and filterbank extraction. It does not perform diarization,
name matching, enrollment migration, or one-second voice qualification.

The model package must be the conversion recorded in
`docs/evidence/2026-09-06-speaker-accuracy.md`, under the native Core ML parity section.
Its input is float32 `[1, frames, 80]` raw filterbank features; the model includes
sentence mean normalization. A different model's similarly shaped input is not
interchangeable. Keep its checkpoint revision, conversion hash and calibrated pack
model ID together. Existing WeSpeaker profiles must never be used with ECAPA vectors.

Compile on macOS with Accelerate and Core ML:

```sh
xcrun swiftc -O -parse-as-library \
  -Xcc -DACCELERATE_NEW_LAPACK -Xcc -DACCELERATE_LAPACK_ILP64 \
  scripts/quality/ecapa/ECAPAFeatures.swift \
  scripts/quality/ecapa/NativeECAPAProbe.swift \
  -o /private/tmp/native-ecapa-probe
/private/tmp/native-ecapa-probe corpus.json output-directory model.mlpackage
```

The corpus contains `cases`, each with `id`, `audio` (local WAV path), `startMs`
and nullable `endMs`. Each selected interval must be 2–30 seconds of 16 kHz mono
audio. Output contains little-endian float32 features and JSON normalized embeddings
with local diagnostic timings. Use a disposable output directory and keep at least
6 GiB free for model compilation and evidence. The runner uses CPU-only Core ML.

The front end uses a 400-sample periodic Hamming window, 160-sample hop, centered
zero padding, 201 power-spectrum bins, and the pinned SpeechBrain model's 80
symmetric triangular mel filters. It applies a 1e-10 power floor and 80 dB dynamic
range. The explicit Accelerate DFT matrices preserve the 400-point transform;
substituting a conventional 512-point FFT changes model inputs. Input and output
allocations are bounded by the 30-second limit. Feature cancellation is checked
every 32 frames; model-call cancellation and app scheduling are not qualified here.

Boundary checks require neither Python nor model weights:

```sh
xcrun swiftc -O -parse-as-library \
  -Xcc -DACCELERATE_NEW_LAPACK -Xcc -DACCELERATE_LAPACK_ILP64 \
  scripts/quality/ecapa/ECAPAFeatures.swift \
  scripts/quality/ecapa/FeatureChecks.swift \
  -o /private/tmp/ecapa-feature-checks
/private/tmp/ecapa-feature-checks
```

The retained 100-input parity experiment and quantized matcher comparison are
stronger numerical evidence than these boundary checks. Neither closes the remaining
mixed-speaker boundary errors, real-meeting accuracy, profile migration or app gates.
