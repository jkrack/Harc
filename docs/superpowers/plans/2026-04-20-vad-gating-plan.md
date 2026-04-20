# VAD Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert `FluidAudio.VadManager` between chunk-receive and Parakeet in the `harc-stt` daemon so silent regions of each chunk are stripped before ASR inference, with full timestamp remapping back to the original chunk timeline.

**Design doc:** `/Users/jlane/GitHub/Harc/docs/superpowers/specs/2026-04-20-vad-gating-design.md`

**Architecture:** Pure helpers live in `HarcSTT`: `VoicedStitcher` (samples + segments → compact buffer + region table) and `VADTimestampRemapper` (compact-timeline words + region table → original-timeline words). `VADGate` wraps `FluidAudio.VadManager` with Harc's default `VadSegmentationConfig` and a compile-time "tiny voiced fraction" short-circuit. `Transcriber` orchestrates: resample → VAD → stitch → transcribe compact → remap. `RequestHandler` forwards the new `TranscribeRequest.vad` flag to `Transcriber`. Client types (`HarcSTTClient`, `ChunkedTranscriber`, `AppDelegate`) thread a `vadEnabled` preference through to each IPC request. Diarization stays on the original file unchanged.

**Tech Stack:** Swift 6, Swift Testing, FluidAudio (already a dep — `VadManager`, `segmentSpeech`, `VadSegmentationConfig`), AppKit/SwiftUI for the Settings toggle.

---

## Dependency graph

```
T1 (IPCRequest.vad field) ───────────────────────────┐
                                                     │
T2 (VoicedStitcher pure)                             │
T3 (VADTimestampRemapper pure)                       │
T4 (VADGate wrapper)                                 │
                                                     │
         ─────▶ T5 (Transcriber + TranscribeService + RequestHandler + FakeTranscriber + TranscriberTests)
                │
                ▼
              T6 (HarcSTTClient + TranscribingClient + ChunkedTranscriber + client-side fakes)
                │
                ▼
T7 (HarcPreferences.vadEnabled) ─────────┐
                                         │
                                         ▼
                                      T8 (RecordingSettingsView toggle)
                                         │
                                         ▼
                                      T9 (AppDelegate wiring)
                                         │
                                         ▼
                                     T10 (end-to-end verification)
```

Tasks 2, 3, 4, 7 are independent and can be parallelised. T1 must land before T5 uses the new field.

---

## Effort summary

| Task | Effort | Gates |
|------|--------|-------|
| 1. `IPCRequest.vad` field + Codable fwd-compat | S | `swift test --filter IPCRequest` |
| 2. `VoicedStitcher` pure | S | `swift test --filter VoicedStitcher` |
| 3. `VADTimestampRemapper` pure | S | `swift test --filter VADTimestampRemapper` |
| 4. `VADGate` wrapper | S | `swift build` |
| 5. `Transcriber` VAD flow + protocol + fake + tests | M | `swift test --filter HarcSTT` |
| 6. `HarcSTTClient` + `ChunkedTranscriber` + client fakes | M | `swift test --filter HarcClient` + `HarcAudio` |
| 7. `HarcPreferences.vadEnabled` + tests | S | `swift test --filter HarcPreferences` |
| 8. `RecordingSettingsView` toggle | S | `xcodebuild` |
| 9. `AppDelegate` wiring | S | `xcodebuild` |
| 10. End-to-end verification | S | full `swift test`, smoke checklist |

---

### Task 1: `TranscribeRequest.vad` field

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcCore/IPCRequest.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcCoreTests/IPCRequestTests.swift`

- [ ] **Step 1: Look for the existing IPCRequest test file**

Run: `ls /Users/jlane/GitHub/Harc/Tests/HarcCoreTests/ 2>/dev/null`
Expected: file list. If `IPCRequestTests.swift` does not exist, create it with the imports + @Suite skeleton below in Step 2. If it exists, append to the existing `@Suite("IPCRequest")`.

- [ ] **Step 2: Write the failing test**

Append inside (or create) `/Users/jlane/GitHub/Harc/Tests/HarcCoreTests/IPCRequestTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcCore

@Suite("TranscribeRequest VAD field")
struct TranscribeRequestVADTests {
    @Test("default init sets vad = true")
    func defaultVADIsTrue() {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav")
        #expect(r.vad == true)
    }

    @Test("explicit init round-trips vad: false")
    func explicitVADFalse() {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)
        #expect(r.vad == false)
    }

    @Test("JSON decode without vad key defaults to true (fwd-compat)")
    func decodeWithoutVADKey() throws {
        let json = #"{"audioPath":"/tmp/x.wav","language":"en","wantTimestamps":true,"diarize":true}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(TranscribeRequest.self, from: json)
        #expect(r.vad == true)
    }

    @Test("JSON decode with vad:false honours the payload")
    func decodeWithVADFalse() throws {
        let json = #"{"audioPath":"/tmp/x.wav","vad":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(TranscribeRequest.self, from: json)
        #expect(r.vad == false)
    }

    @Test("JSON encode includes vad")
    func encodeIncludesVAD() throws {
        let r = TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"vad\":false"))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter TranscribeRequestVADTests`
Expected: compile error — `TranscribeRequest` has no `vad` member.

- [ ] **Step 4: Add the `vad` field**

In `/Users/jlane/GitHub/Harc/Sources/HarcCore/IPCRequest.swift`, replace the `TranscribeRequest` struct with:

```swift
public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var language: String
    public var wantTimestamps: Bool
    public var diarize: Bool
    public var vad: Bool

    public init(
        audioPath: String,
        language: String = "en",
        wantTimestamps: Bool = true,
        diarize: Bool = true,
        vad: Bool = true
    ) {
        self.audioPath = audioPath
        self.language = language
        self.wantTimestamps = wantTimestamps
        self.diarize = diarize
        self.vad = vad
    }

    private enum CodingKeys: String, CodingKey {
        case audioPath, language, wantTimestamps, diarize, vad
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.audioPath = try c.decode(String.self, forKey: .audioPath)
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.wantTimestamps = try c.decodeIfPresent(Bool.self, forKey: .wantTimestamps) ?? true
        self.diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? true
        self.vad = try c.decodeIfPresent(Bool.self, forKey: .vad) ?? true
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TranscribeRequestVADTests`
Expected: all 5 tests pass.

- [ ] **Step 6: Run the full suite to catch any call-site compile breaks**

Run: `swift build`
Expected: build succeeds. All existing `TranscribeRequest(...)` call sites use named args, so the new defaulted parameter inserts cleanly.

- [ ] **Step 7: Commit**

```bash
git add Sources/HarcCore/IPCRequest.swift Tests/HarcCoreTests/IPCRequestTests.swift
git commit -m "$(cat <<'EOF'
feat(core): TranscribeRequest.vad field (default true, fwd-compat)

decodeIfPresent means old clients without the field get VAD by default.
Consumed by the daemon's new VAD gate (next tasks).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `VoicedStitcher` (pure)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VoicedStitcher.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/VoicedStitcherTests.swift`

`VoicedStitcher` concatenates voiced regions from an original sample buffer into a compact buffer and records a region table used by the remapper.

- [ ] **Step 1: Write the failing tests**

Create `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/VoicedStitcherTests.swift`:

```swift
import Testing
import Foundation
import FluidAudio
@testable import HarcSTT

@Suite("VoicedStitcher")
struct VoicedStitcherTests {
    /// Build a VadSegment whose startTime/endTime convert to the requested
    /// sample indices at the given sample rate.
    private func seg(startSample: Int, endSample: Int, rate: Int) -> VadSegment {
        VadSegment(
            startTime: Double(startSample) / Double(rate),
            endTime: Double(endSample) / Double(rate)
        )
    }

    @Test("stitch — empty segments → empty compact buffer + empty regions")
    func emptySegments() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(samples: samples, segments: [], sampleRate: 8)
        #expect(out.compactSamples.isEmpty)
        #expect(out.regions.isEmpty)
    }

    @Test("stitch — single region copied verbatim")
    func singleRegion() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 2, endSample: 5, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples == [2, 3, 4])
        #expect(out.regions.count == 1)
        #expect(out.regions[0].origStartSample == 2)
        #expect(out.regions[0].origEndSample == 5)
        #expect(out.regions[0].compactStartSample == 0)
        #expect(out.regions[0].sampleCount == 3)
    }

    @Test("stitch — two regions concatenated with cumulative compactStart")
    func twoRegions() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [
                seg(startSample: 1, endSample: 3, rate: 8),  // → [1,2]
                seg(startSample: 5, endSample: 7, rate: 8),  // → [5,6]
            ],
            sampleRate: 8
        )
        #expect(out.compactSamples == [1, 2, 5, 6])
        #expect(out.regions.count == 2)
        #expect(out.regions[0].compactStartSample == 0)
        #expect(out.regions[0].sampleCount == 2)
        #expect(out.regions[1].compactStartSample == 2)
        #expect(out.regions[1].sampleCount == 2)
    }

    @Test("stitch — out-of-bounds segment is clamped to samples")
    func clampedToBounds() {
        let samples: [Float] = [0, 1, 2, 3]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 2, endSample: 10, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples == [2, 3])
        #expect(out.regions[0].origEndSample == 4) // clamped to samples.count
    }

    @Test("stitch — zero-length segment after clamp is dropped")
    func zeroLengthDropped() {
        let samples: [Float] = [0, 1, 2, 3]
        let out = VoicedStitcher.stitch(
            samples: samples,
            segments: [seg(startSample: 5, endSample: 7, rate: 8)],
            sampleRate: 8
        )
        #expect(out.compactSamples.isEmpty)
        #expect(out.regions.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VoicedStitcherTests`
Expected: compile error — `VoicedStitcher`, `VoicedRegion`, `StitchResult` do not exist.

- [ ] **Step 3: Create `VoicedStitcher.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VoicedStitcher.swift`:

```swift
import Foundation
import FluidAudio

/// Maps a subrange of the original sample buffer to its offset in the
/// compact (stitched) buffer. `compactStartSample` is the first sample
/// index of this region in the compact buffer; the region ends at
/// `compactStartSample + sampleCount`.
public struct VoicedRegion: Equatable, Sendable {
    public let origStartSample: Int
    public let origEndSample: Int
    public let compactStartSample: Int

    public var sampleCount: Int { origEndSample - origStartSample }

    public init(origStartSample: Int, origEndSample: Int, compactStartSample: Int) {
        self.origStartSample = origStartSample
        self.origEndSample = origEndSample
        self.compactStartSample = compactStartSample
    }
}

/// Output of `VoicedStitcher.stitch`: the compact sample buffer plus
/// the ordered region table used by `VADTimestampRemapper`.
public struct StitchResult: Equatable, Sendable {
    public let compactSamples: [Float]
    public let regions: [VoicedRegion]

    public init(compactSamples: [Float], regions: [VoicedRegion]) {
        self.compactSamples = compactSamples
        self.regions = regions
    }
}

/// Pure: concatenate the voiced regions of `samples` into a compact
/// `[Float]` and record each region's placement in the compact buffer.
/// Out-of-bounds segments are clamped; zero-length results are dropped.
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

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VoicedStitcherTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/VoicedStitcher.swift Tests/HarcSTTTests/VoicedStitcherTests.swift
git commit -m "$(cat <<'EOF'
feat(stt): VoicedStitcher pure — samples + VadSegments → compact buffer

Pure helper that concatenates voiced regions of a 16kHz sample buffer
into a compact buffer and records each region's (origStart, origEnd,
compactStart). Clamps out-of-bounds segments; drops zero-length.
Consumed by the Transcriber VAD path (later task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `VADTimestampRemapper` (pure)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VADTimestampRemapper.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/VADTimestampRemapperTests.swift`

Maps compact-timeline `Word`s (what Parakeet returns when fed a stitched buffer) back to original-timeline `Word`s using the region table produced by `VoicedStitcher.stitch`.

- [ ] **Step 1: Write the failing tests**

Create `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/VADTimestampRemapperTests.swift`:

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("VADTimestampRemapper")
struct VADTimestampRemapperTests {
    /// Rate: 8 samples/sec so 1 sample = 125 ms. Makes arithmetic easy.
    private let rate = 8

    /// Three voiced regions in the original:
    ///   region 0: orig [0,   1000ms)  → compact [0,   1000ms)
    ///   region 1: orig [2000,3000ms)  → compact [1000,2000ms)
    ///   region 2: orig [5000,5500ms)  → compact [2000,2500ms)
    /// Sample counts at 8Hz: 8, 8, 4 → compact = 20 samples.
    private var regions: [VoicedRegion] {
        [
            VoicedRegion(origStartSample: 0,  origEndSample: 8,  compactStartSample: 0),
            VoicedRegion(origStartSample: 16, origEndSample: 24, compactStartSample: 8),
            VoicedRegion(origStartSample: 40, origEndSample: 44, compactStartSample: 16),
        ]
    }

    @Test("remap — empty regions returns words unchanged")
    func emptyRegions() {
        let words = [Word(text: "hi", startMs: 100, endMs: 200)]
        #expect(VADTimestampRemapper.remap(words: words, regions: []) == words)
    }

    @Test("remap — word entirely in first region preserves ms (compactStart == origStart == 0)")
    func firstRegion() {
        let words = [Word(text: "a", startMs: 250, endMs: 750)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out == [Word(text: "a", startMs: 250, endMs: 750)])
    }

    @Test("remap — word entirely in second region shifts by region offset")
    func secondRegion() {
        // compact ms 1000..1500 corresponds to orig region[1] offset 0..500 → 2000..2500
        let words = [Word(text: "b", startMs: 1000, endMs: 1500)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out == [Word(text: "b", startMs: 2000, endMs: 2500)])
    }

    @Test("remap — word at a region boundary maps to the new region's start")
    func regionBoundary() {
        // compact ms 1000 = exactly the boundary; start should be region[1].origStart = 2000.
        let words = [Word(text: "c", startMs: 1000, endMs: 1125)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out[0].startMs == 2000)
        #expect(out[0].endMs == 2125)
    }

    @Test("remap — word past all regions clamps to final region's tail")
    func pastAllRegions() {
        // compact ms 3000 is past compact end (2500). Clamp into region[2]'s tail (origEnd = 5500ms).
        let words = [Word(text: "d", startMs: 3000, endMs: 3500)]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        #expect(out[0].startMs == 5500)
        #expect(out[0].endMs == 5500)
    }

    @Test("remap — consecutive words preserve monotonic non-decreasing start times")
    func monotonic() {
        let words = [
            Word(text: "w1", startMs: 100, endMs: 500),
            Word(text: "w2", startMs: 600, endMs: 900),
            Word(text: "w3", startMs: 1100, endMs: 1400),
            Word(text: "w4", startMs: 2100, endMs: 2300),
        ]
        let out = VADTimestampRemapper.remap(words: words, regions: regions, sampleRate: rate)
        var prev = -1
        for w in out {
            #expect(w.startMs >= prev)
            prev = w.startMs
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VADTimestampRemapperTests`
Expected: compile error — `VADTimestampRemapper` does not exist.

- [ ] **Step 3: Create `VADTimestampRemapper.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VADTimestampRemapper.swift`:

```swift
import Foundation
import HarcCore

/// Pure: convert Parakeet `Word`s from the compact (stitched) timeline
/// back to the original chunk timeline using the region table produced
/// by `VoicedStitcher.stitch`. `endMs` is bounded below by `startMs` so
/// each word's range remains well-formed after region-crossing.
public enum VADTimestampRemapper {
    public static func remap(
        words: [Word],
        regions: [VoicedRegion],
        sampleRate: Int = 16000
    ) -> [Word] {
        guard !regions.isEmpty else { return words }
        return words.map { word in
            let startMs = remapCompactMs(word.startMs, regions: regions, sampleRate: sampleRate)
            let endMs = remapCompactMs(word.endMs, regions: regions, sampleRate: sampleRate)
            return Word(text: word.text, startMs: startMs, endMs: max(startMs, endMs))
        }
    }

    /// Find the region containing `compactMs` and return the corresponding
    /// original-timeline ms. If `compactMs` is past the last region, returns
    /// the last region's tail (origEnd in ms).
    static func remapCompactMs(_ compactMs: Int, regions: [VoicedRegion], sampleRate: Int) -> Int {
        let compactSamples = compactMs * sampleRate / 1000
        var containing: VoicedRegion = regions.last!
        for r in regions {
            let regionCompactEnd = r.compactStartSample + r.sampleCount
            if compactSamples < regionCompactEnd {
                containing = r
                break
            }
        }
        let offsetIntoRegion = compactSamples - containing.compactStartSample
        let clamped = max(0, min(offsetIntoRegion, containing.sampleCount))
        let origSamples = containing.origStartSample + clamped
        return origSamples * 1000 / sampleRate
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VADTimestampRemapperTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSTT/VADTimestampRemapper.swift Tests/HarcSTTTests/VADTimestampRemapperTests.swift
git commit -m "$(cat <<'EOF'
feat(stt): VADTimestampRemapper pure — compact → original timeline

Given Parakeet word timestamps on the stitched compact timeline and the
region table from VoicedStitcher, returns the same words with original
chunk-timeline startMs/endMs. endMs >= startMs invariant preserved via
max(). Past-end compact times clamp to the final region's tail.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `VADGate` wrapper

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VADGate.swift`

Wraps `FluidAudio.VadManager` with Harc's default `VadSegmentationConfig`, lazy load, and the "tiny voiced fraction" short-circuit predicate. No unit tests here (requires loading a CoreML model — integration-level, covered in Task 5's daemon path).

- [ ] **Step 1: Create `VADGate.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcSTT/VADGate.swift`:

```swift
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's `VadManager` with Harc-specific defaults. Loads the
/// Silero VAD CoreML model once and keeps it resident; owns the
/// `VadSegmentationConfig` (hard-coded to `.default`). Provides a
/// compile-time "skip Parakeet if voiced duration too small" predicate
/// used by `Transcriber`.
public actor VADGate {
    private var manager: VadManager?
    private let segmentationConfig = VadSegmentationConfig.default

    /// Parakeet on clips shorter than this tends to return garbage or
    /// drop the audio; better to skip the pass entirely. Not configurable.
    public static let minVoicedSeconds: Double = 0.5

    public init() {}

    public var isLoaded: Bool { manager != nil }

    /// Load the Silero VAD model. Safe to call repeatedly; no-op when loaded.
    public func loadModel() async throws {
        guard manager == nil else { return }
        self.manager = try await VadManager()
    }

    /// Segment `samples` (16 kHz mono Float32) into speech regions.
    public func segments(in samples: [Float]) async throws -> [VadSegment] {
        guard let manager else { throw DaemonError.modelNotLoaded }
        return try await manager.segmentSpeech(samples, config: segmentationConfig)
    }

    /// True iff the segments cover at least `minVoicedSeconds` of audio.
    public static func hasMinimumVoicedDuration(_ segments: [VadSegment]) -> Bool {
        let total = segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        return total >= minVoicedSeconds
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcSTT/VADGate.swift
git commit -m "$(cat <<'EOF'
feat(stt): VADGate — actor wrapping FluidAudio.VadManager

Owns the Silero model lifetime (lazy load), carries Harc's default
VadSegmentationConfig, and exposes a hasMinimumVoicedDuration helper
used to short-circuit Parakeet when a chunk has < 500 ms of speech.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `Transcriber` VAD flow + `TranscribeService` + `RequestHandler` + tests

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/Transcriber.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcSTT/RequestHandler.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/RequestHandlerTests.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/TranscriberTests.swift`

This task changes the `TranscribeService` protocol (breaking change), updates the single conforming type (`Transcriber`), the single fake (`FakeTranscriber` in tests), and the call site (`RequestHandler`). The compiler enforces consistency — the whole bundle lands in one commit.

- [ ] **Step 1: Update `TranscribeService` protocol + `RequestHandler` call site**

In `/Users/jlane/GitHub/Harc/Sources/HarcSTT/RequestHandler.swift`:

**(a)** Replace the protocol:

```swift
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
}
```

**(b)** Update the `transcribe(_:)` internal method call site:

Find:

```swift
            textResult = try await transcriber.transcribe(audioPath: req.audioPath)
```

Replace with:

```swift
            textResult = try await transcriber.transcribe(audioPath: req.audioPath, vad: req.vad)
```

- [ ] **Step 2: Update the `FakeTranscriber` to match the new protocol**

In `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/RequestHandlerTests.swift`:

Replace the `FakeTranscriber` actor with:

```swift
    actor FakeTranscriber: TranscribeService {
        var loadCalled = false
        var lastPath: String?
        var lastVAD: Bool?
        var result: TranscribeResult = TranscribeResult(
            text: "fake", words: [], speakers: [], processingMs: 1
        )

        func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult {
            lastPath = audioPath
            lastVAD = vad
            return result
        }

        var isLoaded: Bool { true }
    }
```

- [ ] **Step 3: Add a test asserting that `RequestHandler` threads `req.vad` to the service**

Append inside `RequestHandlerTests`:

```swift
    @Test("transcribe request threads req.vad to TranscribeService")
    func transcribePassesVAD() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        _ = await handler.handle(.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)))
        #expect(await fake.lastVAD == false)

        _ = await handler.handle(.transcribe(TranscribeRequest(audioPath: "/tmp/y.wav")))
        #expect(await fake.lastVAD == true)
    }
```

- [ ] **Step 4: Extend `Transcriber` with the VAD flow**

Replace the body of `/Users/jlane/GitHub/Harc/Sources/HarcSTT/Transcriber.swift` with:

```swift
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's ASR pipeline (Parakeet TDT v3) for CoreML inference on
/// ANE/Metal, with an optional VAD pre-filter that strips silent regions and
/// remaps Parakeet's timestamps back to the original chunk timeline.
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
        // VAD is an optimisation — its failure must never block ASR load.
        do {
            try await vadGate.loadModel()
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: VAD model load failed (\(error.localizedDescription)) — transcription will run without VAD\n".utf8
            ))
        }
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
        do {
            result = try await manager.transcribe(samples)
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let compactWords: [Word] = (result.tokenTimings ?? []).map { t in
            Word(
                text: t.token,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }
        let words = regions.map {
            VADTimestampRemapper.remap(words: compactWords, regions: $0)
        } ?? compactWords

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }
}
```

- [ ] **Step 5: Update `TranscriberTests` to the new signature**

In `/Users/jlane/GitHub/Harc/Tests/HarcSTTTests/TranscriberTests.swift`, replace the body with:

```swift
import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("Transcriber", .tags(.slow))
struct TranscriberTests {
    @Test("transcribing short-speech.wav with vad: false produces non-empty text and word timings")
    func transcribeShortSpeechVADOff() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path, vad: false)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        #expect(result.words.count > 0, "expected at least one word timing")
        #expect(result.processingMs > 0, "processingMs should be positive")
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
    }

    @Test("transcribing short-speech.wav with vad: true keeps transcript similar and timestamps in range")
    func transcribeShortSpeechVADOn() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "short-speech", withExtension: "wav", subdirectory: "Fixtures")
        )

        let transcriber = Transcriber()
        try await transcriber.loadModels()

        let result: TranscribeResult = try await transcriber.transcribe(audioPath: url.path, vad: true)

        #expect(!result.text.isEmpty, "expected transcribed text from fixture")
        // Fixture is ~3 seconds of speech with minimal silence — VAD should not produce empty output.
        #expect(result.text.lowercased().contains("test"), "expected 'test' in transcription; got: \(result.text)")
        // Every word's timestamps must fit within the fixture's 3-second duration.
        for w in result.words {
            #expect(w.startMs >= 0, "negative startMs: \(w)")
            #expect(w.endMs <= 3_200, "endMs past fixture duration: \(w)")   // 3s + tiny padding slack
            #expect(w.endMs >= w.startMs, "endMs before startMs: \(w)")
        }
    }

    @Test("transcribe before loadModels throws .modelNotLoaded (vad: false)")
    func transcribeBeforeLoadThrows() async throws {
        let transcriber = Transcriber()
        await #expect(throws: DaemonError.modelNotLoaded) {
            _ = try await transcriber.transcribe(audioPath: "/tmp/does-not-matter.wav", vad: false)
        }
    }
}

extension Tag {
    @Tag static var slow: Self
}
```

- [ ] **Step 6: Build and test**

Run: `swift build`
Expected: build succeeds.

Run: `swift test --filter HarcSTT`
Expected: all HarcSTTTests pass. The slow-tagged `Transcriber` tests will actually load Parakeet + VAD models and exercise real inference; they may take 30–60 s on first run (model download). If model download is not desired in CI, gate with `.tags(.slow)` as already done.

- [ ] **Step 7: Commit**

```bash
git add Sources/HarcSTT/Transcriber.swift Sources/HarcSTT/RequestHandler.swift Tests/HarcSTTTests/RequestHandlerTests.swift Tests/HarcSTTTests/TranscriberTests.swift
git commit -m "$(cat <<'EOF'
feat(stt): Transcriber VAD flow + TranscribeService carries vad:

Transcriber.transcribe now gains a vad: Bool parameter. When true, the
chunk is resampled, VAD-segmented, voice-stitched into a compact buffer,
transcribed by Parakeet on the compact buffer, and Parakeet's word
timestamps are remapped to the original chunk timeline. A VAD failure
falls through to unfiltered transcription (logged to stderr). A chunk
with < 500 ms of voiced audio short-circuits Parakeet entirely and
returns empty words. TranscribeService protocol, FakeTranscriber, and
RequestHandler updated together to keep compilation atomic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `HarcSTTClient` + `TranscribingClient` + `ChunkedTranscriber` + client-side fakes

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcClient/HarcSTTClient.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcClient/ChunkedTranscriber.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/ChunkedTranscriberTests.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift`

Threads the new `vad: Bool` through the client stack. The `TranscribingClient` protocol signature changes; the two fakes that conform must update in the same commit.

- [ ] **Step 1: Update `TranscribingClient` protocol and `HarcSTTClient.transcribe`**

In `/Users/jlane/GitHub/Harc/Sources/HarcClient/ChunkedTranscriber.swift`, replace the protocol declaration at the top of the file:

```swift
/// Protocol boundary for testing — any client that can transcribe a WAV path.
public protocol TranscribingClient: Sendable {
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult
}
```

In `/Users/jlane/GitHub/Harc/Sources/HarcClient/HarcSTTClient.swift`, find the existing `transcribe` method:

```swift
public func transcribe(audioPath: String, diarize: Bool = true) async throws -> TranscribeResult {
```

Replace with:

```swift
public func transcribe(audioPath: String, diarize: Bool = true, vad: Bool = true) async throws -> TranscribeResult {
```

In the same function body, find where it constructs the `TranscribeRequest` and add `vad: vad`. Read the file first to locate the constructor; add the new named arg.

- [ ] **Step 2: Update `ChunkedTranscriber` to carry `vadEnabled`**

In `/Users/jlane/GitHub/Harc/Sources/HarcClient/ChunkedTranscriber.swift`:

**(a)** Replace the stored-property block and initializer with:

```swift
    private let client: any TranscribingClient
    private let diarize: Bool
    private let vadEnabled: Bool
    private let chunkDurationSeconds: Double
    private let pollIntervalSeconds: Double
    private let vocabulary: Vocabulary

    nonisolated(unsafe) private let assembler = TranscriptAssembler()
    private var chunker: WAVChunker?
    private var audioURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    public let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    public init(
        client: any TranscribingClient,
        diarize: Bool = true,
        vadEnabled: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0,
        vocabulary: Vocabulary = .empty
    ) {
        self.client = client
        self.diarize = diarize
        self.vadEnabled = vadEnabled
        self.chunkDurationSeconds = chunkDurationSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.vocabulary = vocabulary
        let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
        self.updates = stream
        self.updatesContinuation = cont
    }
```

**(b)** Find the call to `client.transcribe(audioPath:, diarize:)` (around line 104):

```swift
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: diarize)
```

Replace with:

```swift
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: diarize, vad: vadEnabled)
```

- [ ] **Step 3: Update the `FakeClient` in `ChunkedTranscriberTests`**

In `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/ChunkedTranscriberTests.swift`, replace the `FakeClient` actor with:

```swift
    actor FakeClient: TranscribingClient {
        var calls: [(path: String, diarize: Bool, vad: Bool)] = []
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
            calls.append((audioPath, diarize, vad))
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }
```

Note: if existing tests in that file assert on `calls`, their assertions may need the extra tuple field. Read the file and update any such assertions minimally.

- [ ] **Step 4: Update the `StubClient` in `RecordingSessionTranscriptionTests`**

In `/Users/jlane/GitHub/Harc/Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift`, replace the `StubClient` actor with:

```swift
    actor StubClient: TranscribingClient {
        var results: [TranscribeResult]
        init(results: [TranscribeResult]) { self.results = results }
        func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
            if results.isEmpty {
                return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
            }
            return results.removeFirst()
        }
    }
```

- [ ] **Step 5: Check existing tests that call `HarcSTTClient.transcribe(audioPath:diarize:)`**

Two existing call sites use only the two-arg form:
- `Tests/HarcClientTests/EndToEndTests.swift:45`
- `Tests/HarcClientTests/HarcSTTClientTests.swift:62,82`

Because `vad` is defaulted to `true`, they still compile. Leave them as-is — the default is documented and this exercises the "default on" path.

- [ ] **Step 6: Build and test**

Run: `swift build`
Expected: build succeeds.

Run: `swift test --filter HarcClient`
Expected: all `HarcClient` tests pass.

Run: `swift test --filter HarcAudio`
Expected: all `HarcAudio` tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/HarcClient/HarcSTTClient.swift Sources/HarcClient/ChunkedTranscriber.swift Tests/HarcClientTests/ChunkedTranscriberTests.swift Tests/HarcAudioTests/RecordingSessionTranscriptionTests.swift
git commit -m "$(cat <<'EOF'
feat(client): thread vad: Bool through TranscribingClient / ChunkedTranscriber

HarcSTTClient.transcribe gains vad: Bool = true. TranscribingClient
protocol gains the same parameter. ChunkedTranscriber adds a
vadEnabled init parameter (default true) and forwards it on every
per-chunk call. Client-side fakes in ChunkedTranscriberTests and
RecordingSessionTranscriptionTests updated to match.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `HarcPreferences.vadEnabled`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/HarcPreferencesTests.swift`

New `@Published` Bool following the same pattern as `autoPasteEnabled` from the previous feature.

- [ ] **Step 1: Write the failing test**

Append inside the `struct HarcPreferencesTests` in `/Users/jlane/GitHub/Harc/Tests/HarcUITests/HarcPreferencesTests.swift`:

```swift
    @Test("vadEnabled defaults to true when UserDefaults has no key")
    func vadEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.vadEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.vadEnabled == true)
    }

    @Test("vadEnabled persists and round-trips through UserDefaults")
    func vadEnabledPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.vadEnabled")
        let prefs = HarcPreferences()
        prefs.vadEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.vadEnabled == false)
        defaults.removeObject(forKey: "harc.vadEnabled")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HarcPreferencesTests`
Expected: compile error — `HarcPreferences` has no `vadEnabled` member.

- [ ] **Step 3: Add `vadEnabled` to `HarcPreferences`**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`:

**(a)** Add a new constant to the private `Key` enum at the top of the class, after the existing `autoPasteEnabled`:

```swift
        static let vadEnabled = "harc.vadEnabled"
```

**(b)** Add a new `@Published` property, after the existing `autoPasteEnabled`:

```swift
    @Published public var vadEnabled: Bool {
        didSet { UserDefaults.standard.set(vadEnabled, forKey: Key.vadEnabled) }
    }
```

**(c)** Initialize in `init()`, after the existing `autoPasteEnabled` initialization:

```swift
        self.vadEnabled = defaults.object(forKey: Key.vadEnabled) as? Bool ?? true
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HarcPreferencesTests`
Expected: all HarcPreferencesTests pass.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/HarcPreferences.swift Tests/HarcUITests/HarcPreferencesTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): HarcPreferences.vadEnabled (default true)

Persisted at harc.vadEnabled. Drives the Settings toggle (next task)
and the vadEnabled parameter on ChunkedTranscriber.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `RecordingSettingsView` toggle

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/RecordingSettingsView.swift`

Add the Settings toggle in a new "Processing" section. No unit test — SwiftUI layout.

- [ ] **Step 1: Locate the insertion point**

The existing `Form { ... }` currently has sections (in order): Destination folder → Chunk duration → Auto-paste → Global hotkey → Meeting detection. Insert the new **Processing** section BETWEEN **Chunk duration** and **Auto-paste**. That positions processing-related toggles next to each other (Chunk duration and Voice-activity detection are both "how transcription happens").

- [ ] **Step 2: Add the new Section**

Find the `Section { KeyboardShortcuts.Recorder... } header: { Text("Auto-paste") } ...` (or the Auto-paste section introduced by the prior feature — look for `Toggle("Auto-paste on stop", isOn: $prefs.autoPasteEnabled)`). Insert BEFORE that Section:

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

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds (ignore pre-existing multi-destination warning).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/Settings/RecordingSettingsView.swift
git commit -m "$(cat <<'EOF'
feat(ui): Settings — Voice-activity detection toggle

New "Processing" section between Chunk duration and Auto-paste. Toggle
binds to prefs.vadEnabled. Footer explains speed/battery tradeoff and
when to disable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `AppDelegate` wiring

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

Pass `prefs.vadEnabled` into the `ChunkedTranscriber(...)` initializer in `startRecording()`.

- [ ] **Step 1: Find the existing `ChunkedTranscriber(...)` call site**

Open `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift` and search for `ChunkedTranscriber(`. The existing call looks like:

```swift
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                chunkDurationSeconds: prefs.chunkDurationSeconds,
                vocabulary: prefs.vocabulary
            )
```

- [ ] **Step 2: Thread `vadEnabled`**

Replace the call site above with:

```swift
            let transcriber = ChunkedTranscriber(
                client: client,
                diarize: prefs.diarize,
                vadEnabled: prefs.vadEnabled,
                chunkDurationSeconds: prefs.chunkDurationSeconds,
                vocabulary: prefs.vocabulary
            )
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(app): pass prefs.vadEnabled into ChunkedTranscriber

Closes the Settings toggle → IPC path for VAD.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: End-to-end manual verification

**Files:** none.

- [ ] **Step 1: Full test suite green**

Run: `swift test`
Expected: 0 failures, including pure-unit tests from Tasks 1–3, the updated Transcriber tests from Task 5 (slow — runs real inference), and the updated client fakes from Task 6.

If the slow `.tags(.slow)` Transcriber tests download Parakeet / Silero models on first run, the first `swift test` may take several minutes. Subsequent runs hit the on-disk model cache and complete in ~30 s.

- [ ] **Step 2: Xcode build**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 3: Scan for new warnings**

Run: `swift build 2>&1 | grep -E 'warning:' | grep -vE 'TranscriptHitHighlight' || echo "no new warnings"`
Expected: `no new warnings`.

- [ ] **Step 4: Smoke — VAD on, solo dictation**

Launch Harc. Settings → Recording → confirm the **Processing / Voice-activity detection** toggle is ON.

Record ~60 seconds of slow dictation with long thinking pauses (aim for ~50% silence). Stop. Expect:
- Transcript appears correctly (reads as the words you spoke).
- No error icon on the menu bar.
- `tail -n 100 ~/.harc/stt.log 2>/dev/null` or `log show --predicate 'process == "harc-stt"' --last 5m 2>/dev/null` may show the daemon's stderr. (If no log file exists, launch Harc from a terminal: `Harc.app/Contents/MacOS/Harc` — stderr streams to that terminal.)

- [ ] **Step 5: Smoke — VAD off for comparison**

Flip the toggle OFF. Record the same 60-second cadence. Expect:
- Transcript is (nearly) identical to Step 4.
- Daemon stderr's per-chunk `processingMs` is noticeably higher — often 1.5–2× — compared to Step 4, because Parakeet is now processing the full 60 s per chunk instead of only the voiced regions. Write down the approximate numbers for a before/after sanity check.

Flip back ON.

- [ ] **Step 6: Smoke — VAD handles silence gracefully**

Start a recording. Stay silent for ~30 seconds. Stop. Expect:
- Transcript is empty or nearly empty (no hallucinated words).
- No crash, no error dialog.
- Daemon stderr shows the chunk was short-circuited (voiced fraction below minimum); no ASR pass ran.

- [ ] **Step 7: Smoke — meeting-style mixed audio**

Join a brief call (or play a video with spoken audio) so ScreenCaptureKit captures system audio. Start a recording, speak intermittently while the other audio plays, stop after 2–3 minutes. Expect:
- Transcript is correct and includes both your speech and the remote speech.
- No audio quality regression vs VAD-off.
- `processingMs` savings are smaller than solo dictation (the mixed stream has less silence), but still positive.

- [ ] **Step 8: Edge — VAD failure fallback**

(Optional but recommended.) Simulate a VAD model load failure by temporarily renaming the Silero cache directory before starting the app:

```bash
mv ~/Library/Application\ Support/FluidAudio/Models ~/Library/Application\ Support/FluidAudio/Models.bak 2>/dev/null || true
```

Launch Harc. Record a short clip. Expect:
- `harc-stt` stderr logs a VAD-related load or inference failure.
- Transcript still appears correctly (fell through to unfiltered path).

Restore:

```bash
mv ~/Library/Application\ Support/FluidAudio/Models.bak ~/Library/Application\ Support/FluidAudio/Models 2>/dev/null || true
```

- [ ] **Step 9: Final tidy**

If anything surfaced during smoke that should live in the spec (e.g., a behavior clarification, a default change), update `docs/superpowers/specs/2026-04-20-vad-gating-design.md` and commit separately. Otherwise no further commits.

---

## Self-review notes

- **Spec coverage.** §3 output invariants — tests in T3 pin monotonicity and bounds; T5 asserts word timestamps are within the fixture duration. §4 architecture — T4 (VADGate) + T5 (Transcriber flow). §4.3 short-circuit — `VADGate.minVoicedSeconds` + the `hasMinimumVoicedDuration` check in Transcriber. §4.4 VAD failure fallback — the `do/catch` in `Transcriber.transcribe`. §4.5 timestamp math — T3 tests. §5 code architecture — T1 (core), T4/T5 (HarcSTT), T6 (HarcClient), T7 (HarcPreferences), T8 (Settings), T9 (AppDelegate wiring). §6 testing — all three layers represented (pure unit in T2/T3, integration in T5 `.slow`, manual in T10).
- **Type consistency.** `VoicedRegion` / `StitchResult` / `VadSegment` / `Word` / `TranscribeResult` / `AutoPasteDecision`... checked: every name used in T5's Transcriber body is defined in T2 (`VoicedRegion`, `StitchResult`) or T3 (`VADTimestampRemapper.remap`) or T4 (`VADGate`, `VADGate.minVoicedSeconds`, `VADGate.hasMinimumVoicedDuration`). `TranscribeService.transcribe(audioPath:vad:)` is consistent between T5's protocol update and T5's FakeTranscriber update.
- **Commit cadence.** One commit per task. T5 and T6 are each "one semantic change" commits even though they touch multiple files, because the protocol-signature changes are breaking and must land atomically with their conforming types.
- **Manual-smoke scope.** Restricted to behaviors this feature changes; does not re-verify recording, export, or auto-paste flows from prior features.
- **`.slow`-tagged integration tests.** The Transcriber tests in T5 require real model downloads on first run. `.tags(.slow)` is the existing pattern; tests remain runnable but can be filtered out of fast dev loops via `swift test --skip 'slow'` if needed.
