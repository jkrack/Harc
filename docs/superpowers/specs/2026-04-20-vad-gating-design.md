# VAD Gating Design Doc

**Feature:** Insert Voice Activity Detection (VAD) between chunk-receive and Parakeet inference in the `harc-stt` daemon. Strip silent regions from each chunk before transcription so Parakeet processes roughly `voiced_fraction × chunk_duration` seconds instead of the full chunk.
**Date:** 2026-04-20
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Harc's primary cost centre on Apple Silicon is Parakeet inference. For a 60-second chunk, Parakeet runs against the whole thing regardless of how much of it contains speech. In two of the three dominant use cases, a large fraction of the chunk is silence:

- **Solo dictation (vibe-coding a spec, composing a draft, voice memos):** ~50–70% silence (think-time between sentences, long pauses while re-reading).
- **Meeting-with-remote-participants where you're on mute:** approaches 100% silence on the mic side, though the ScreenCaptureKit system-audio side remains voiced.
- **Live meeting (all speakers talking):** ~10–30% silence, usually punctuation/breath gaps.

Cutting silence before Parakeet gives roughly proportional CPU / Neural Engine savings — a 50%-silent chunk becomes half a Parakeet pass. Battery, heat, and wall-clock latency on the "incremental background transcription during recording" path all improve.

**User story (no change, quieter).** The user records as today; transcripts appear with the same accuracy; laptop fan stays quieter, battery lasts longer.

**User story (failure mode).** If a VAD regression clips a word, the user toggles **Voice-activity detection** off in Settings → Recording. Re-running transcription on the on-disk WAV (out of scope for this spec, but already possible because the durability contract preserves the raw audio) produces the unfiltered transcript.

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- Daemon-side VAD between chunk-receive and Parakeet. Consumes `FluidAudio.VadManager` (already transitively depended upon via the `FluidAudio` package).
- Per-chunk **within-chunk filter**: segment speech regions, concatenate them into a compact sample buffer, run Parakeet on that buffer, remap Parakeet's word timestamps back to the original chunk timeline.
- New `vad: Bool` field on `TranscribeRequest` (default `true`, backward-compatible via `decodeIfPresent`).
- New `vadEnabled: Bool` preference in `HarcPreferences` (default `true`).
- Settings toggle in `RecordingSettingsView` that maps preference → IPC request.
- Short-circuit: if the chunk has no voiced regions (or total voiced duration is below a safe minimum), skip Parakeet entirely and return an empty `TranscribeResult`.
- Safe fallback: if VAD throws, log and transcribe the original chunk unchanged.
- Unit tests for the pure stitching and timestamp-remapping logic; integration tests for the daemon path using a recorded fixture.

**Out of scope / non-goals (v1):**

- **User-tunable VAD thresholds.** FluidAudio's `VadSegmentationConfig.default` is well-tuned (0.15s min speech, 0.75s min silence, 14s max speech, 0.1s padding). Do not surface these in UI. Revisit if a real recording proves a regression.
- **Streaming per-frame VAD.** We already process one 60-second chunk at a time — non-streaming `segmentSpeech(_:)` is enough. No need for `processStreamingChunk` stateful decoding.
- **Separate mic-vs-system-audio VAD.** The on-disk WAV is already a mixed single stream; VADing the mix is v1 scope. If savings in live-meeting scenarios turn out to be disappointing, revisit with a mic-only parallel path.
- **VAD-driven chunk boundary adjustment.** Chunk boundaries remain fixed at `chunkDurationSeconds`; VAD runs within each fixed chunk, not across them.
- **Paste-into-library "VAD report"** or metrics UI (voiced-fraction, savings). Out of scope; stderr logging in the daemon is enough for v1.
- **Disabling VAD per-recording.** Toggle is global via Settings; per-recording knobs are YAGNI.
- **Client-side VAD.** Placing VAD in the client would require loading Silero in the app process, doubling RAM / startup cost. Daemon-side is strictly better given the FluidAudio integration already lives there.
- **Changing diarization input.** Diarization runs on the original full audio file (`audioPath`) via `RequestHandler.diarize`, unchanged by VAD. Speaker boundaries benefit from the silence/breath context that Parakeet no longer needs.

---

## 3. Output invariants

For any chunk, the daemon's `TranscribeResult` when `vad: true` must satisfy:

1. **Timestamps are in the ORIGINAL chunk timeline.** A word's `startMs` is the millisecond offset into the submitted chunk's audio, not into the VAD-compacted buffer. Clients downstream (`TranscriptAssembler`, `ExportInputBuilder`) need this to stitch chunk results together.
2. **Monotonic non-decreasing `startMs`** across `words`. Never decreasing as you read left-to-right.
3. **`0 <= startMs <= endMs <= chunkDurationMs`** — no word's timestamp exceeds the chunk's own duration.
4. **`speakers` array unchanged by VAD.** Diarization uses the original audio via `RequestHandler`, so speaker segments cover the original timeline regardless of the `vad` flag.
5. **When `vad: false`, behavior is byte-identical to today.** The same request produces the same result as before this feature landed.
6. **Empty-chunk short-circuit.** If total voiced duration across all VAD segments is strictly less than `minVoicedMs` (500 ms — see §4.3), return `TranscribeResult(text: "", words: [], speakers: <diarization output>, processingMs: <VAD time + 0>)`. No Parakeet call.

---

## 4. Daemon architecture

```
Client: ChunkedTranscriber ──▶ IPC(transcribe, vad: true, audioPath: <tmp.wav>)
                                          │
                                    RequestHandler.transcribe(req)
                                          │
                   ┌──────────────────────┴──────────────────────┐
                   ▼                                             ▼
           Transcriber.transcribe(                         diarizer?.diarize(
               audioPath:,                                    audioPath: <original file>)
               vad: req.vad                                 — unchanged, runs on original
           )
                   │
                   ▼
      audioConverter.resampleAudioFile → [Float] 16kHz mono
                   │
                   ▼
         if !vad  { transcribe(samples) → words (timeline identity) }
         else
                   ▼
         VADGate.segments(samples, sampleRate: 16000)
                   │
                   ├─ [] or total <500ms  → return empty TranscribeResult
                   │
                   ▼
         VoicedStitcher.stitch(samples, segments, sampleRate: 16000)
                   │
                   ├─▶ compactSamples: [Float]
                   └─▶ regions: [VoicedRegion]  (origStart, origEnd, compactStart — all in samples)
                   │
                   ▼
         asrManager.transcribe(compactSamples) → ASRResult
                   │
                   ▼
         VADTimestampRemapper.remap(words, regions, sampleRate: 16000) → [Word]
                   │
                   ▼
         return TranscribeResult(text, words, speakers: [], processingMs)
                   │
                   │
      RequestHandler attaches diarizer.diarize(audioPath:) speakers (unchanged)
                   │
                   ▼
         IPC response: .result(TranscribeResult)
```

### 4.1 Sample-rate contract

All VAD / stitch / remap logic operates on **16 kHz Float32 mono** — the same shape `audioConverter.resampleAudioFile(path:)` already returns. `VadManager.segmentSpeech(samples, config:)` is documented as requiring 16 kHz mono; `AudioConverter` does the rate/channel conversion once. No conversion duplication anywhere in this pipeline.

### 4.2 VAD configuration

Use `VadSegmentationConfig.default` verbatim:

| Knob | Default | Meaning |
|---|---|---|
| `minSpeechDuration` | 0.15 s | Drop speech regions shorter than this |
| `minSilenceDuration` | 0.75 s | Merge two speech regions separated by shorter silence |
| `maxSpeechDuration` | 14.0 s | Split over-long regions at natural silence |
| `speechPadding` | 0.10 s | Bleed-out padding around each region — preserves word onsets/offsets that Silero narrows aggressively |
| other | default | Silero entry-threshold defaults |

Hard-code in a single `VADGate` initializer. Not configurable from outside the daemon in v1.

### 4.3 Short-circuit thresholds

- **No voiced regions.** `VadManager.segmentSpeech` returns `[]`. Skip Parakeet. Return empty result.
- **Tiny voiced fraction.** If `segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }` is less than `0.5` seconds, skip Parakeet. Parakeet on a <500ms clip often either returns garbage or drops the audio entirely; the savings outweigh the risk of losing a stray "yeah". This threshold is a compile-time constant `VADGate.minVoicedSeconds = 0.5` — not user-tunable.

### 4.4 VAD failure path

If any of `VadGate.load`, `VadGate.segments`, or `VoicedStitcher.stitch` throws, catch it inside `Transcriber`, log to `stderr` with the chunk's `audioPath`, and fall through to the `vad: false` code path — submit the original full sample buffer to Parakeet. VAD is an optimisation; its failure must never fail a transcription.

### 4.5 Timestamp remap math

For each VAD segment `[origStart_i, origEnd_i]` (in samples), we record the compact offset where its samples begin:

```
compactStart_0 = 0
compactStart_{i+1} = compactStart_i + (origEnd_i - origStart_i)
```

Each `VoicedRegion` is the triple `(origStart, origEnd, compactStart)`. Given a Parakeet word with `startSampleCompact` and `endSampleCompact`:

1. Find the region with `compactStart <= startSampleCompact < compactStart + (origEnd - origStart)`.
2. `wordOrigStart = origStart + (startSampleCompact - compactStart)`.
3. `wordOrigEnd` is computed the same way using the word's end sample (may cross into the next region if Parakeet's word spans a silence-removed boundary — use the containing region of the end sample). The remapped `endMs >= startMs` invariant holds because Parakeet itself emits monotonic timestamps on its own compact timeline.

Expressed in milliseconds (what `Word` carries):

```swift
wordStartMs = Int(Double(origStart + (wordStartSamplesCompact - compactStart))
                  / Double(sampleRate) * 1000)
```

Tests pin this arithmetic for boundary cases.

---

## 5. Code architecture

All changes contained to **HarcCore** (one request field), **HarcSTT** (daemon), **HarcClient** (one pass-through), **HarcUI** (one preference + toggle), **HarcApp** (one wiring line). No new SwiftPM target. No new third-party package.

### 5.1 HarcCore — new field on `TranscribeRequest`

**Extended:** `Sources/HarcCore/IPCRequest.swift`

```swift
public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var language: String
    public var wantTimestamps: Bool
    public var diarize: Bool
    public var vad: Bool            // NEW — default true

    public init(
        audioPath: String,
        language: String = "en",
        wantTimestamps: Bool = true,
        diarize: Bool = true,
        vad: Bool = true
    ) { ... }

    private enum CodingKeys: String, CodingKey {
        case audioPath, language, wantTimestamps, diarize, vad
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.audioPath = try c.decode(String.self, forKey: .audioPath)
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.wantTimestamps = try c.decodeIfPresent(Bool.self, forKey: .wantTimestamps) ?? true
        self.diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? true
        self.vad = try c.decodeIfPresent(Bool.self, forKey: .vad) ?? true     // NEW
    }
}
```

`decodeIfPresent(...) ?? true` matches the existing forward-compat pattern and means an old client that does not know about `vad` gets VAD by default. Since client and daemon are versioned together in practice, this is mostly for resilience to rolling builds.

### 5.2 HarcSTT — new files + extended `Transcriber`

**New:** `Sources/HarcSTT/VADGate.swift`

```swift
import Foundation
import FluidAudio

/// Wraps FluidAudio's VadManager with Harc-specific defaults, a safe-fallback
/// path, and a compile-time "tiny voiced fraction" short-circuit. Owns the
/// VAD model lifetime the same way `Transcriber` owns the ASR model.
public actor VADGate {
    private var manager: VadManager?

    public static let minVoicedSeconds: Double = 0.5
    private let segmentationConfig = VadSegmentationConfig.default

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func loadModel() async throws {
        guard manager == nil else { return }
        self.manager = try await VadManager()
    }

    /// Returns the speech regions detected in `samples` (16 kHz mono Float32),
    /// or an empty array if nothing voiced was found.
    public func segments(in samples: [Float]) async throws -> [VadSegment] {
        guard let manager else { throw DaemonError.modelNotLoaded }
        return try await manager.segmentSpeech(samples, config: segmentationConfig)
    }

    /// True iff VAD segments cover at least `minVoicedSeconds` of the input.
    public static func hasMinimumVoicedDuration(_ segments: [VadSegment]) -> Bool {
        let total = segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        return total >= minVoicedSeconds
    }
}
```

**New:** `Sources/HarcSTT/VoicedStitcher.swift`

Pure type. Given `[VadSegment]` and the original `[Float]` samples, returns the concatenated compact buffer plus the region table used by the remapper.

```swift
public struct VoicedRegion: Equatable, Sendable {
    public let origStartSample: Int
    public let origEndSample: Int
    public let compactStartSample: Int
    public var sampleCount: Int { origEndSample - origStartSample }
}

public struct StitchResult: Equatable, Sendable {
    public let compactSamples: [Float]
    public let regions: [VoicedRegion]
}

public enum VoicedStitcher {
    public static func stitch(
        samples: [Float],
        segments: [VadSegment],
        sampleRate: Int = 16000
    ) -> StitchResult {
        var compact: [Float] = []
        compact.reserveCapacity(
            segments.reduce(0) { $0 + $1.sampleCount(sampleRate: sampleRate) }
        )
        var regions: [VoicedRegion] = []
        regions.reserveCapacity(segments.count)
        var compactCursor = 0
        for seg in segments {
            let lo = max(0, seg.startSample(sampleRate: sampleRate))
            let hi = min(samples.count, seg.endSample(sampleRate: sampleRate))
            guard lo < hi else { continue }
            compact.append(contentsOf: samples[lo..<hi])
            regions.append(VoicedRegion(
                origStartSample: lo,
                origEndSample: hi,
                compactStartSample: compactCursor
            ))
            compactCursor += (hi - lo)
        }
        return StitchResult(compactSamples: compact, regions: regions)
    }
}
```

**New:** `Sources/HarcSTT/VADTimestampRemapper.swift`

Pure type. Given Parakeet `Word`s (compact timeline, ms) and a `[VoicedRegion]`, returns the same words with original-timeline ms.

```swift
public enum VADTimestampRemapper {
    public static func remap(
        words: [Word],
        regions: [VoicedRegion],
        sampleRate: Int = 16000
    ) -> [Word] {
        guard !regions.isEmpty else { return words }
        return words.map { word in
            let startMs = remapSampleMs(word.startMs, regions: regions, sampleRate: sampleRate)
            let endMs   = remapSampleMs(word.endMs,   regions: regions, sampleRate: sampleRate)
            return Word(text: word.text, startMs: startMs, endMs: max(startMs, endMs))
        }
    }

    /// Map a compact-timeline millisecond to the original timeline using the
    /// region table. Clamps to the containing region; when ms is past the last
    /// region the last region's tail is used.
    static func remapSampleMs(_ compactMs: Int, regions: [VoicedRegion], sampleRate: Int) -> Int {
        let compactSamples = compactMs * sampleRate / 1000
        var region = regions[0]
        for r in regions {
            let regionCompactEnd = r.compactStartSample + r.sampleCount
            if compactSamples < regionCompactEnd { region = r; break }
            region = r
        }
        let offsetIntoRegion = max(0, compactSamples - region.compactStartSample)
        let clamped = min(offsetIntoRegion, region.sampleCount)
        let origSamples = region.origStartSample + clamped
        return origSamples * 1000 / sampleRate
    }
}
```

**Extended:** `Sources/HarcSTT/Transcriber.swift`

```swift
public actor Transcriber {
    private var asrManager: AsrManager?
    private let audioConverter = AudioConverter()
    private let vadGate: VADGate

    public init(vadGate: VADGate = VADGate()) {
        self.vadGate = vadGate
    }

    public var isLoaded: Bool { asrManager != nil }

    public func loadModels() async throws {
        guard asrManager == nil else { return }
        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        try await manager.loadModels(models)
        self.asrManager = manager
        try? await vadGate.loadModel()       // best-effort; VAD failure never fails ASR load
    }

    public func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult {
        guard let manager = asrManager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        if !vad {
            return try await runParakeet(on: samples, with: manager, regions: nil)
        }

        // VAD path — any VAD error falls through to unfiltered transcription.
        let segments: [VadSegment]
        do {
            segments = try await vadGate.segments(in: samples)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: VAD failed (\(error.localizedDescription)) — falling back to full chunk transcription for \(audioPath)\n".utf8
            ))
            return try await runParakeet(on: samples, with: manager, regions: nil)
        }

        guard VADGate.hasMinimumVoicedDuration(segments) else {
            return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
        }

        let stitch = VoicedStitcher.stitch(samples: samples, segments: segments)
        return try await runParakeet(on: stitch.compactSamples, with: manager, regions: stitch.regions)
    }

    private func runParakeet(
        on samples: [Float],
        with manager: AsrManager,
        regions: [VoicedRegion]?
    ) async throws -> TranscribeResult {
        let start = DispatchTime.now()
        let result: ASRResult
        do { result = try await manager.transcribe(samples) }
        catch { throw DaemonError.transcriptionFailed(error.localizedDescription) }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let compactWords: [Word] = (result.tokenTimings ?? []).map {
            Word(text: $0.token, startMs: Int($0.startTime * 1000), endMs: Int($0.endTime * 1000))
        }
        let words = regions.map { VADTimestampRemapper.remap(words: compactWords, regions: $0) }
            ?? compactWords

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }
}
```

**Extended:** `Sources/HarcSTT/RequestHandler.swift`

Change the `TranscribeService` protocol and the call site:

```swift
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
}

// In handle() → transcribe(req):
textResult = try await transcriber.transcribe(audioPath: req.audioPath, vad: req.vad)
```

Diarization call is unchanged — it reads `req.audioPath` directly.

### 5.3 HarcClient — pass the preference through

**Extended:** `Sources/HarcClient/HarcSTTClient.swift`

`transcribe(...)` gains a `vad: Bool` parameter (default `true`) and forwards it into `TranscribeRequest`.

**Extended:** `Sources/HarcClient/ChunkedTranscriber.swift`

Initializer gains `vadEnabled: Bool` (default `true`); each call to `client.transcribe(...)` passes it through.

### 5.4 HarcUI — preference + Settings row

**Extended:** `Sources/HarcUI/HarcPreferences.swift`

```swift
private enum Key {
    // ... existing keys ...
    static let vadEnabled = "harc.vadEnabled"
}

@Published public var vadEnabled: Bool {
    didSet { UserDefaults.standard.set(vadEnabled, forKey: Key.vadEnabled) }
}

// in init():
self.vadEnabled = defaults.object(forKey: Key.vadEnabled) as? Bool ?? true
```

**Extended:** `Sources/HarcUI/Settings/RecordingSettingsView.swift`

Add a new Section beside the existing Chunk-duration one:

```swift
Section {
    Toggle("Voice-activity detection", isOn: $prefs.vadEnabled)
        .tint(HarcDesign.primary)
} header: {
    Text("Processing")
} footer: {
    Text("Skips silent regions before transcription. Faster and quieter on battery; disable if you suspect a word is being clipped.")
        .font(HarcDesign.Font.bodySm)
        .foregroundStyle(Color.harcOnSurfaceVariant)
}
```

### 5.5 HarcApp — wire the preference into ChunkedTranscriber

**Extended:** `HarcApp/AppDelegate.swift`

In `startRecording()`, pass `vadEnabled: prefs.vadEnabled` into the `ChunkedTranscriber(...)` initializer.

---

## 6. Testing

### 6.1 Pure unit (no model load)

- **`VoicedStitcherTests`** — handcrafted samples arrays (e.g. `[0, 1, 2, 3, 4, 5, 6, 7]` at sampleRate 8) with known `VadSegment`s, assert compact buffer and region table match. Boundary cases: empty segments, out-of-bounds segment clamping, single-segment stitch, multi-segment stitch.
- **`VADTimestampRemapperTests`** — table-driven: for a known region table, input compact `Word`s at known millisecond offsets, assert remapped `startMs`/`endMs`. Invariants: monotonic non-decreasing, remapped range within original bounds. Edge cases: word entirely in first region, word entirely in last region, word whose compact `startMs` equals a region boundary, word past all regions (clamped to last region's tail).

### 6.2 Integration (daemon path)

- **`VADGateIntegrationTests`** — loads VAD model, runs a small fixture (≈1 second of pre-recorded speech, ≈1 second of silence, mixed). Assert voiced-segment count ≥1 on speech, 0 on silence, and voiced fraction within ±10% of the hand-annotated ground truth for the mixed clip.
- Extend `HarcClient end-to-end` suite (existing daemon-launch harness in `Tests/HarcClientTests/`) with two cases against the same fixture:
  - `transcribe(..., vad: false)` — reference transcript.
  - `transcribe(..., vad: true)` — assert transcript equals reference (exact text) or within a 1-word Levenshtein tolerance, and that every returned word's `startMs`/`endMs` lies within the original fixture's duration (i.e. remap produced sane values).

### 6.3 Manual smoke

- Record 90s of solo dictation with long thinking pauses. Compare (a) transcript text and (b) daemon stderr "processingMs" between VAD-on and VAD-off. Expect ≥30% reduction in processingMs, identical transcript.
- Record a 10-minute Zoom call with ScreenCaptureKit capture running (you talking ~30% of the time). Expect ~20% reduction, identical transcript.
- Flip the Settings toggle mid-session. The next chunk (not the in-flight one) should honour the new value.
- Revoke VAD model (temporarily rename the download cache dir) and record. Expect daemon stderr log, full-chunk fallback, transcript unchanged.

---

## 7. Error handling & observability

- **Daemon logs** (stderr, existing pattern in `Daemon.swift`):
  - VAD load failure on daemon boot — logged, `loadModels()` returns success anyway (ASR still works).
  - VAD inference failure per chunk — logged with `audioPath`, falls back to unfiltered transcription.
  - Empty-voiced short-circuit — no log; this is the expected path and logging would be noise.
- **IPC errors** — none new. `TranscribeResult` with empty `words` is not an error.
- **Client-side** — no new error paths. `ChunkedTranscriber` already copes with empty results (the existing "entirely silent chunk" case).

---

## 8. Open decisions captured

- **Default ON.** Matches the "zero quality loss, clear speed win" framing of the brief. Users who hit a regression toggle off; the raw WAV is on disk and can always be re-transcribed with VAD off.
- **Daemon-side, not client-side.** `FluidAudio` already lives in the daemon; loading Silero in the app process would double the model-memory footprint (two Silero instances, same model bytes) for no benefit.
- **Use `segmentSpeech` (non-streaming) not `processStreamingChunk`.** The daemon receives whole 60s chunks, not a live byte stream — the streaming API's event-based state machine would be throwaway complexity.
- **Hard-coded `minVoicedSeconds = 0.5`.** Parakeet on a sub-500ms clip is unreliable; dropping it is cheaper than a wrong transcript. Not user-tunable.
- **Diarization stays on the original file.** The diarizer benefits from silence / breath context to find speaker boundaries. Running diarization on the compact buffer would save a little CPU but at real risk of mis-boundary detection.
- **`VadSegmentationConfig.default` verbatim.** Don't surface these in UI. Revisit only if real recordings show a regression that moving `speechPadding` or `minSilenceDuration` would fix.

---

## 9. Sequencing with the rest of Tier 1

- **#3 Copy for Prompt** — ✅ shipped.
- **#1 Auto-paste** — ✅ shipped.
- **#2 VAD (this spec)** — next.
- **#4 Speaker renaming** — independent. VAD doesn't touch speaker segments (diarization stays on the original audio); #4 can land before or after without interaction.
