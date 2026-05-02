# Fluid Waveform Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 40-bar peak meter (`LiveScopeView`) with a fluid-water waveform viz across menu bar icon, panel, and toolbar pill, plus a static amplitude envelope in the detail view.

**Architecture:** New `LiveWaveformView` (kinetic, three size variants) consumes a renamed `amplitudeHistory` from `AutoStopController`. New `StaticWaveformView` + `AmplitudeEnvelopeLoader` render finished WAVs in the detail view. `WavePalette` is a local viz palette (not in `HarcBrand`). The compound recording pill keeps a red dot for the recording semantic and adds a blue waveform inside one glass capsule.

**Tech Stack:** SwiftUI on macOS 26 (`Canvas`, `TimelineView(.animation)`, `LinearGradient`), Swift Testing for new tests, existing FluidAudio/Combine/GRDB stack untouched.

**Spec:** `docs/superpowers/specs/2026-05-01-fluid-waveform-viz-design.md`

**Branch:** Continues on `feat/native-ui-rebuild-2026-04-27` (worktree at `/Users/jlane/GitHub/Harc/.worktrees/native-ui-rebuild-2026-04-27`). PR #36 is open; this work appends to it.

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `Sources/HarcUI/WavePalette.swift` | Three blue/cyan colors for waveform fill, edge, and stroke. Local to the viz; not in `HarcBrand`. |
| `Sources/HarcUI/LiveWaveformView.swift` | Kinetic fluid-water waveform renderer. Three size variants (`.icon`, `.panel`, `.pill`). Reads `history: [Float]` by value. |
| `Sources/HarcUI/StaticWaveformView.swift` | Frozen mirror-of-amplitude renderer for finished recordings. No animation. |
| `Sources/HarcUI/AmplitudeEnvelopeLoader.swift` | Streams a 16 kHz mono Int16 WAV → `[Float]` peak envelope. Async, LRU-cached. |
| `Tests/HarcUITests/AmplitudeEnvelopeLoaderTests.swift` | TDD'd tests for the loader: shape, range, cache hit. |

### Modified

| Path | Change |
|---|---|
| `Sources/HarcUI/AutoStopController.swift` | Rename `scopeHistory` → `amplitudeHistory`. Bump capacity 40 → 96. Bump update rate (interval 0.15 s → 0.04 s, ~24 Hz). Pre-fill with zeros. Silence detection unchanged. |
| `Sources/HarcUI/HarcAppBridge.swift` | Rename `scopeHistory` → `amplitudeHistory`. |
| `HarcApp/AppDelegate.swift` | Rename Combine forwarding sink. |
| `HarcApp/HarcApp.swift` | `MenuBarExtraLabel` swaps to `LiveWaveformView(.icon)`. `MenuBarExtraContent` passes `bridge.amplitudeHistory`. |
| `Sources/HarcUI/MenuBarPanelView.swift` | Replace `LiveScopeView` call with `LiveWaveformView(.panel)`. Rename param. |
| `Sources/HarcUI/HarcWindowRootView.swift` | Add `amplitudeHistory` to init. Rewrite recording pill (red dot + waveform on glass). Add `StaticWaveformView` + envelope loading at the top of the detail pane. |
| `HarcApp/WindowControllers/HarcWindowController.swift` | Plumb `amplitudeHistory` from bridge to `HarcWindowRootView`. |
| `Tests/HarcUITests/AutoStopControllerTests.swift` | Add tests for `amplitudeHistory` length, rolling, idle behavior. |

### Deleted

| Path | Why |
|---|---|
| `Sources/HarcUI/LiveScopeView.swift` | Replaced by `LiveWaveformView`. |

---

## Phase 0 — Brand + palette setup

### Task 0.1: Add `WavePalette`

**Files:**
- Create: `Sources/HarcUI/WavePalette.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Local palette for the fluid-water waveform viz. Deliberately NOT in
/// HarcBrand — the brand sliver stays minimal (recording red + app
/// gradient). These three colors only exist to render the live and
/// static waveforms; if you find yourself reaching for them elsewhere,
/// that's a sign the palette needs to graduate.
public enum WavePalette {
    /// Center of the gradient — deep blue, sits on the horizontal axis.
    public static let center = Color(red: 0x1B/255.0, green: 0x4F/255.0, blue: 0x8C/255.0)

    /// Edge of the gradient — soft cyan, marks the wave peaks.
    public static let edge = Color(red: 0x5C/255.0, green: 0xD2/255.0, blue: 0xFF/255.0)

    /// Highlight stroke on the upper wave layer — light cyan, like light
    /// catching the water surface.
    public static let stroke = Color(red: 0x9C/255.0, green: 0xE2/255.0, blue: 0xFF/255.0)
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/WavePalette.swift
git commit -m "$(cat <<'EOF'
feat(ui): WavePalette — local blue/cyan palette for waveform viz

Three colors for the fluid-water waveform fill/edge/stroke. Kept local
to the viz files; not in HarcBrand to preserve the minimal brand sliver.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 — `AmplitudeEnvelopeLoader` (TDD)

### Task 1.1: Tests first

**Files:**
- Create: `Tests/HarcUITests/AmplitudeEnvelopeLoaderTests.swift`

- [ ] **Step 1: Locate the test fixture**

```bash
ls Tests/HarcSTTTests/Fixtures/short-speech.wav
```

Expected: file exists. We'll reference it from the new test by reaching into the HarcSTT test bundle's resources, OR by copying the path. Easiest: the test reads the WAV via absolute path constructed from `#filePath`. Sample shape:

```swift
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fixture = here
    .deletingLastPathComponent()      // Tests/
    .appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav")
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/HarcUITests/AmplitudeEnvelopeLoaderTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcUI

@Suite("AmplitudeEnvelopeLoader")
@MainActor
struct AmplitudeEnvelopeLoaderTests {

    private static var fixtureURL: URL {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav")
    }

    @Test("returns array of requested sample count")
    func returnsRequestedSampleCount() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(envelope.count == 256)
    }

    @Test("all values are in [0, 1]")
    func valuesNormalized() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        for v in envelope {
            #expect(v >= 0)
            #expect(v <= 1)
        }
    }

    @Test("at least one sample exceeds 0.1 (fixture has audible speech)")
    func envelopeHasContent() async throws {
        let envelope = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let maxVal = envelope.max() ?? 0
        #expect(maxVal > 0.1, "expected at least one envelope sample > 0.1; got max \(maxVal)")
    }

    @Test("cache returns identical contents on second call")
    func cacheHit() async throws {
        let first = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        let second = try await AmplitudeEnvelopeLoader.load(
            url: Self.fixtureURL,
            samples: 256
        )
        #expect(first == second)
    }

    @Test("missing file throws")
    func missingFileThrows() async {
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-a-real-harc-file-\(UUID().uuidString).wav")
        await #expect(throws: (any Error).self) {
            _ = try await AmplitudeEnvelopeLoader.load(url: bogus, samples: 64)
        }
    }
}
```

- [ ] **Step 3: Run tests, verify failure (`AmplitudeEnvelopeLoader` does not exist)**

```bash
swift test --filter AmplitudeEnvelopeLoaderTests 2>&1 | tail -10
```

Expected: compilation failure — `AmplitudeEnvelopeLoader` not found.

### Task 1.2: Implement the loader

**Files:**
- Create: `Sources/HarcUI/AmplitudeEnvelopeLoader.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import AVFoundation

/// Decodes a 16 kHz mono Int16 WAV (Harc's recording format) into a
/// fixed-length array of normalized peak amplitudes for visualization.
///
/// Streams the file in chunks so multi-hour recordings don't load the
/// entire WAV into memory. Results are cached by `(absolute path, sample
/// count)`; the cache is a small LRU keyed off the same tuple.
public enum AmplitudeEnvelopeLoader {

    /// Loads `url` and returns `samples`-length `[Float]` of normalized
    /// peak amplitudes. Each output value is `max(|s|) / Int16.max` over
    /// roughly `totalFrames / samples` consecutive frames of the WAV.
    public static func load(url: URL, samples: Int = 1024) async throws -> [Float] {
        let key = CacheKey(path: url.standardizedFileURL.path, samples: samples)
        if let cached = await cache.get(key) {
            return cached
        }
        let env = try await Task.detached(priority: .userInitiated) {
            try decodeEnvelope(url: url, samples: samples)
        }.value
        await cache.put(key, env)
        return env
    }

    // MARK: - Private

    private struct CacheKey: Hashable, Sendable {
        let path: String
        let samples: Int
    }

    private static let cache = EnvelopeCache(capacity: 16)

    private static func decodeEnvelope(url: URL, samples outSamples: Int) throws -> [Float] {
        // Use AVAudioFile so we tolerate any compatible PCM encoding the
        // user might point at (Harc itself writes 16 kHz mono Int16, but
        // the loader doesn't have to assume).
        let file = try AVAudioFile(forReading: url)
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, outSamples > 0 else { return [] }

        let framesPerBin = max(1, Int(totalFrames) / outSamples)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerBin)) else {
            throw NSError(domain: "AmplitudeEnvelopeLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to allocate decode buffer."
            ])
        }

        var envelope = [Float](repeating: 0, count: outSamples)
        var globalMax: Float = 0

        for i in 0..<outSamples {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerBin))
            let read = Int(buffer.frameLength)
            if read == 0 { break }
            let peak = peakAmplitude(in: buffer, frameCount: read)
            envelope[i] = peak
            globalMax = max(globalMax, peak)
        }

        // Normalize to [0, 1] by global max so quiet recordings still
        // render visibly. If the file is silent, leave at zeros.
        if globalMax > 0 {
            for i in envelope.indices { envelope[i] /= globalMax }
        }
        return envelope
    }

    private static func peakAmplitude(in buffer: AVAudioPCMBuffer, frameCount: Int) -> Float {
        if let floats = buffer.floatChannelData {
            let chan = floats[0]
            var peak: Float = 0
            for i in 0..<frameCount {
                let v = abs(chan[i])
                if v > peak { peak = v }
            }
            return peak
        }
        if let int16s = buffer.int16ChannelData {
            let chan = int16s[0]
            var peak: Int32 = 0
            for i in 0..<frameCount {
                let v = Int32(chan[i].magnitude)
                if v > peak { peak = v }
            }
            return Float(peak) / Float(Int16.max)
        }
        return 0
    }
}

// MARK: - LRU cache

private actor EnvelopeCache {
    private let capacity: Int
    private var entries: [AmplitudeEnvelopeLoader.CacheKey: [Float]] = [:]
    private var order: [AmplitudeEnvelopeLoader.CacheKey] = []

    init(capacity: Int) { self.capacity = capacity }

    func get(_ key: AmplitudeEnvelopeLoader.CacheKey) -> [Float]? {
        guard let value = entries[key] else { return nil }
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
            order.append(key)
        }
        return value
    }

    func put(_ key: AmplitudeEnvelopeLoader.CacheKey, _ value: [Float]) {
        if entries[key] != nil {
            entries[key] = value
            if let i = order.firstIndex(of: key) {
                order.remove(at: i)
                order.append(key)
            }
            return
        }
        entries[key] = value
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}
```

Note: `private struct CacheKey` inside `AmplitudeEnvelopeLoader` — needs to be visible to the actor. Swift permits this because the actor is in the same file. If the compiler complains about access on the nested type from an outer file, move `CacheKey` to file scope (`fileprivate struct EnvelopeCacheKey`).

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: green. Fix any access-level errors as flagged.

- [ ] **Step 3: Run the tests**

```bash
swift test --filter AmplitudeEnvelopeLoaderTests 2>&1 | tail -10
```

Expected: 5 tests pass.

- [ ] **Step 4: Run full test suite to confirm no regression**

```bash
swift test 2>&1 | tail -3
```

Expected: 377 + 5 = 382 tests passing (or current count + 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/AmplitudeEnvelopeLoader.swift Tests/HarcUITests/AmplitudeEnvelopeLoaderTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): AmplitudeEnvelopeLoader — WAV → normalized peak envelope

Streams a recording's WAV in chunks (one chunk per output sample),
returns an N-length [Float] of normalized peak amplitudes. Async,
LRU-cached (16 entries) so re-selecting a recording in the detail view
returns the previously-decoded envelope instantly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — `LiveWaveformView`

### Task 2.1: Implement the renderer

**Files:**
- Create: `Sources/HarcUI/LiveWaveformView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Fluid-water waveform renderer. Driven entirely by the parent: takes a
/// `history: [Float]` by value, smooths internally, and animates a slow
/// phase drift while `isActive`. Idle (`isActive == false`) collapses to
/// a flat horizontal line — recording state stays unambiguous.
///
/// Three size variants tune sample down-resolution and phase amplitude
/// to fit small (icon), medium (panel), and pill-capsule call sites.
public struct LiveWaveformView: View {

    public enum Size: Sendable, Equatable {
        case icon    // ~14pt, ~32 sample points
        case panel   // ~28pt, full 96 sample points
        case pill    // ~16pt, ~48 sample points
    }

    let history: [Float]
    let size: Size
    let isActive: Bool
    let tint: Color

    @State private var displayed: [Float] = []

    public init(
        history: [Float],
        size: Size,
        isActive: Bool,
        tint: Color = WavePalette.center
    ) {
        self.history = history
        self.size = size
        self.isActive = isActive
        self.tint = tint
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { ctx, sz in
                let smoothed = lowPass(toward: history, from: displayed, factor: 0.07)
                let target = downsample(smoothed, to: targetCount)
                draw(in: ctx, size: sz, samples: target, time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .onChange(of: timeline.date) { _, _ in
                // Drive the in-view smoothing on the timeline cadence.
                displayed = lowPass(toward: history, from: displayed, factor: 0.07)
            }
        }
        .onChange(of: history.count) { _, _ in
            // First-render seed: if we have no displayed yet but history has
            // values, copy them straight in so we don't fade up from zero.
            if displayed.isEmpty { displayed = history }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                // Collapse to flat immediately on stop. The timeline pause
                // means no further phase drift; we just zero out displayed.
                displayed = Array(repeating: 0, count: max(history.count, targetCount))
            }
        }
    }

    // MARK: - Drawing

    private var targetCount: Int {
        switch size {
        case .icon:  return 32
        case .panel: return 96
        case .pill:  return 48
        }
    }

    private var phaseAmplitude: CGFloat {
        switch size {
        case .icon:  return 0.4
        case .panel: return 0.8
        case .pill:  return 0.6
        }
    }

    private func draw(in ctx: GraphicsContext, size sz: CGSize, samples: [Float], time t: TimeInterval) {
        let count = samples.count
        guard count > 1 else { return }
        let midY = sz.height / 2
        let stepX = sz.width / CGFloat(count - 1)

        // Two layers with opposed slow phase drifts (~0.3 Hz, ~0.5 Hz).
        let phase1 = sin(t * 2 * .pi * 0.3) * phaseAmplitude
        let phase2 = sin(t * 2 * .pi * 0.5) * -phaseAmplitude

        // Layer 1 (back, more opaque fill, no stroke)
        let layer1 = wavePath(samples: samples, midY: midY + (isActive ? phase1 : 0), stepX: stepX, sz: sz, gain: 0.95)
        ctx.fill(layer1, with: .linearGradient(
            fillGradient(),
            startPoint: CGPoint(x: 0, y: midY),
            endPoint: CGPoint(x: 0, y: 0)
        ))

        // Layer 2 (front, slightly smaller amplitude, stroke overlay)
        let layer2 = wavePath(samples: samples, midY: midY + (isActive ? phase2 : 0), stepX: stepX, sz: sz, gain: 0.7)
        ctx.fill(layer2, with: .linearGradient(
            fillGradient(opacity: 0.7),
            startPoint: CGPoint(x: 0, y: midY),
            endPoint: CGPoint(x: 0, y: 0)
        ))
        if isActive {
            ctx.stroke(strokePath(samples: samples, midY: midY + phase2, stepX: stepX, sz: sz, gain: 0.7),
                       with: .color(WavePalette.stroke.opacity(0.7)),
                       lineWidth: 1)
        }
    }

    private func wavePath(samples: [Float], midY: CGFloat, stepX: CGFloat, sz: CGSize, gain: CGFloat) -> Path {
        var p = Path()
        // Top edge — left to right
        p.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY * gain))
        for i in 1..<samples.count {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        // Bottom edge — right to left (mirror)
        for i in (0..<samples.count).reversed() {
            let x = CGFloat(i) * stepX
            let y = midY + CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }

    private func strokePath(samples: [Float], midY: CGFloat, stepX: CGFloat, sz: CGSize, gain: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY * gain))
        for i in 1..<samples.count {
            let x = CGFloat(i) * stepX
            let y = midY - CGFloat(samples[i]) * midY * gain
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }

    private func fillGradient(opacity: Double = 1.0) -> Gradient {
        if !isActive {
            // Idle: flat soft blue, no gradient pop.
            return Gradient(colors: [
                tint.opacity(0.25 * opacity),
                tint.opacity(0.15 * opacity),
            ])
        }
        return Gradient(colors: [
            tint.opacity(0.85 * opacity),
            WavePalette.edge.opacity(0.55 * opacity),
            WavePalette.edge.opacity(0.0),
        ])
    }

    // MARK: - Sample handling

    private func downsample(_ src: [Float], to count: Int) -> [Float] {
        guard !src.isEmpty, count > 0 else { return Array(repeating: 0, count: count) }
        if src.count == count { return src }
        if src.count < count {
            // Left-pad with zeros so a partial history is right-anchored
            // (newest sample on the right edge).
            return Array(repeating: 0, count: count - src.count) + src
        }
        // Bin by max — preserves transient peaks at any down-resolution.
        var out = [Float](repeating: 0, count: count)
        let bin = Float(src.count) / Float(count)
        for i in 0..<count {
            let lo = Int(Float(i) * bin)
            let hi = min(src.count, Int(Float(i + 1) * bin))
            var peak: Float = 0
            for j in lo..<hi where src[j] > peak { peak = src[j] }
            out[i] = peak
        }
        return out
    }

    private func lowPass(toward target: [Float], from current: [Float], factor: Float) -> [Float] {
        if current.isEmpty { return target }
        if current.count != target.count { return target }
        var out = current
        for i in out.indices {
            out[i] += (target[i] - current[i]) * factor
        }
        return out
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: green. If `TimelineView(.animation(minimumInterval:paused:))` API doesn't match exactly on macOS 26, fall back to `TimelineView(.animation(minimumInterval: 1.0/30.0))` and gate inside the body on `isActive`.

- [ ] **Step 3: Run full test suite**

```bash
swift test 2>&1 | tail -3
```

Expected: still green (no behavior change yet — `LiveWaveformView` has no consumers).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/LiveWaveformView.swift
git commit -m "$(cat <<'EOF'
feat(ui): LiveWaveformView — fluid-water waveform renderer

Two stacked bezier wave layers with opposed slow phase drift and a
cyan-edge gradient fill. Three size variants (.icon / .panel / .pill)
share one renderer; downsamples by peak-binning. Idle (isActive=false)
freezes to a flat soft-blue line. No consumers yet — wired in subsequent
phases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — `StaticWaveformView` and detail-view wiring

### Task 3.1: Implement the static renderer

**Files:**
- Create: `Sources/HarcUI/StaticWaveformView.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Frozen mirror-of-amplitude renderer for finished recordings. Same
/// visual family as `LiveWaveformView` but no animation, no second
/// layer, no stroke overlay. One filled shape, slightly transparent.
public struct StaticWaveformView: View {

    let envelope: [Float]
    let tint: Color

    public init(envelope: [Float], tint: Color = WavePalette.center) {
        self.envelope = envelope
        self.tint = tint
    }

    public var body: some View {
        Canvas { ctx, sz in
            guard envelope.count > 1 else { return }
            let midY = sz.height / 2
            let stepX = sz.width / CGFloat(envelope.count - 1)

            var p = Path()
            p.move(to: CGPoint(x: 0, y: midY - CGFloat(envelope[0]) * midY))
            for i in 1..<envelope.count {
                let x = CGFloat(i) * stepX
                let y = midY - CGFloat(envelope[i]) * midY
                p.addLine(to: CGPoint(x: x, y: y))
            }
            for i in (0..<envelope.count).reversed() {
                let x = CGFloat(i) * stepX
                let y = midY + CGFloat(envelope[i]) * midY
                p.addLine(to: CGPoint(x: x, y: y))
            }
            p.closeSubpath()

            ctx.fill(p, with: .linearGradient(
                Gradient(colors: [
                    tint.opacity(0.7),
                    WavePalette.edge.opacity(0.3),
                    WavePalette.edge.opacity(0.0),
                ]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: 0, y: 0)
            ))
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: envelope.isEmpty)
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/StaticWaveformView.swift
git commit -m "$(cat <<'EOF'
feat(ui): StaticWaveformView — frozen envelope renderer

Same visual family as LiveWaveformView but no animation. One filled
mirror shape, fades in on envelope load.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.2: Wire envelope loading + StaticWaveformView into the detail pane

**Files:**
- Modify: `Sources/HarcUI/HarcWindowRootView.swift`

- [ ] **Step 1: Add the @State property and loader**

Find the existing `@State private var transcriptText: String = ""` (or similar) declaration in `HarcWindowRootView`. Add alongside:

```swift
@State private var detailEnvelope: [Float] = []
```

Find the existing `.onChange(of: selection)` handler that calls `loadTranscript()`. Extend it:

```swift
.onChange(of: selection) { _, _ in
    loadTranscript()
    Task { await loadEnvelope() }
}
```

Add the loader function next to `loadTranscript`:

```swift
private func loadEnvelope() async {
    guard let rec = currentRecording else {
        detailEnvelope = []
        return
    }
    do {
        detailEnvelope = try await AmplitudeEnvelopeLoader.load(
            url: URL(fileURLWithPath: rec.wavPath),
            samples: 1024
        )
    } catch {
        detailEnvelope = []
    }
}
```

- [ ] **Step 2: Render `StaticWaveformView` at the top of the detail pane**

Find the detail pane's `VStack` (the one containing `SummaryCardView` and the transcript `Text`). Insert above the summary card:

```swift
StaticWaveformView(envelope: detailEnvelope)
    .frame(height: 40)
    .padding(.horizontal)
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 4: Run tests**

```bash
swift test 2>&1 | tail -3
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/HarcWindowRootView.swift
git commit -m "$(cat <<'EOF'
feat(library): show static waveform of selected recording in detail pane

Decodes the WAV via AmplitudeEnvelopeLoader on selection change and
renders StaticWaveformView above the summary card. Display only — no
scrub, no playback. Cache makes re-selection instant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — `AutoStopController` rename + capacity bump

### Task 4.1: Add tests for the new `amplitudeHistory` semantics

**Files:**
- Modify: `Tests/HarcUITests/AutoStopControllerTests.swift`

- [ ] **Step 1: Inspect the existing test file to see the helpers it uses**

```bash
sed -n '1,40p' Tests/HarcUITests/AutoStopControllerTests.swift
```

Note the suite name and any clock/feed helpers (the existing tests likely call a private `feed(...)` helper to inject `AudioLevels` samples).

- [ ] **Step 2: Add new tests at the bottom of the suite**

```swift
@Test("amplitudeHistory has fixed capacity of 96 once filled")
func amplitudeHistoryFixedCapacity() async throws {
    let c = AutoStopController()
    c.beginForTesting()
    // Push 200 samples; only the last 96 should remain.
    for i in 0..<200 {
        c.consumeForTesting(level: AudioLevels(
            micDb: -20,
            systemDb: -.infinity,
            smoothedDb: -20,
            fftBins: Array(repeating: Float(i % 5) / 5.0, count: 5)
        ))
    }
    #expect(c.amplitudeHistory.count == 96)
}

@Test("amplitudeHistory rolls — newest sample last")
func amplitudeHistoryRolls() async throws {
    let c = AutoStopController()
    c.beginForTesting()
    // Push 100 samples with monotonically rising amplitude.
    for i in 0..<100 {
        let level = Float(i) / 100.0
        c.consumeForTesting(level: AudioLevels(
            micDb: -10,
            systemDb: -.infinity,
            smoothedDb: -10 - (1 - level) * 30,    // rising
            fftBins: [0, 0, 0, 0, 0]
        ))
    }
    let last = c.amplitudeHistory.last ?? 0
    let first = c.amplitudeHistory.first ?? 1
    #expect(last >= first, "expected later samples to be at least as loud as earlier ones")
}
```

**Note:** the existing test file may use different helper names (`beginForTesting`, `consumeForTesting`). Check first; reuse exactly what's there. If those helpers don't exist, the existing tests likely call the public `begin(session:startedAt:)` and use a manually-constructed `AudioLevels` flow — match that pattern.

- [ ] **Step 3: Run new tests, expect FAIL (the property is still named `scopeHistory`)**

```bash
swift test --filter AutoStopControllerTests 2>&1 | tail -10
```

Expected: compilation failure on `c.amplitudeHistory`.

### Task 4.2: Rename and bump capacity in `AutoStopController`

**Files:**
- Modify: `Sources/HarcUI/AutoStopController.swift`

- [ ] **Step 1: Rename `scopeHistory` → `amplitudeHistory` everywhere in the file**

Find:
```swift
@Published public private(set) var scopeHistory: [Float] = []
```
Replace with:
```swift
@Published public private(set) var amplitudeHistory: [Float] = Array(repeating: 0, count: Self.amplitudeCapacity)
```

Find:
```swift
public static let scopeBarInterval: TimeInterval = 0.150
public static let scopeBarCapacity: Int = 40
```
Replace with:
```swift
public static let amplitudeInterval: TimeInterval = 1.0 / 24.0
public static let amplitudeCapacity: Int = 96
```

Find:
```swift
private var scopeWindowMax: Float = 0
private var scopeWindowStartedAt: Date?
```
Rename to:
```swift
private var amplitudeWindowMax: Float = 0
private var amplitudeWindowStartedAt: Date?
```

In `consume(_ level:)`:

Find:
```swift
if scopeWindowStartedAt == nil { scopeWindowStartedAt = now }
let normalized = max(0, min(1, (level.smoothedDb - Self.dbFloor) / abs(Self.dbFloor)))
scopeWindowMax = max(scopeWindowMax, normalized)
if let windowStart = scopeWindowStartedAt,
   now.timeIntervalSince(windowStart) >= Self.scopeBarInterval {
    scopeHistory.append(scopeWindowMax)
    if scopeHistory.count > Self.scopeBarCapacity {
        scopeHistory.removeFirst(scopeHistory.count - Self.scopeBarCapacity)
    }
    scopeWindowMax = 0
    scopeWindowStartedAt = now
}
```
Replace with:
```swift
if amplitudeWindowStartedAt == nil { amplitudeWindowStartedAt = now }
let normalized = max(0, min(1, (level.smoothedDb - Self.dbFloor) / abs(Self.dbFloor)))
amplitudeWindowMax = max(amplitudeWindowMax, normalized)
if let windowStart = amplitudeWindowStartedAt,
   now.timeIntervalSince(windowStart) >= Self.amplitudeInterval {
    amplitudeHistory.append(amplitudeWindowMax)
    if amplitudeHistory.count > Self.amplitudeCapacity {
        amplitudeHistory.removeFirst(amplitudeHistory.count - Self.amplitudeCapacity)
    }
    amplitudeWindowMax = 0
    amplitudeWindowStartedAt = now
}
```

In any reset/begin path that previously did `scopeHistory = []`, change to:
```swift
amplitudeHistory = Array(repeating: 0, count: Self.amplitudeCapacity)
```
And reset `amplitudeWindowMax = 0; amplitudeWindowStartedAt = nil`.

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: errors in `HarcAppBridge.swift`, `AppDelegate.swift`, `MenuBarPanelView.swift`, `LiveScopeView.swift` — all referencing the old name. Do not fix them yet; the next phases handle each.

If you want to short-circuit the cascade for one build pass, temporarily add a deprecation alias inside `AutoStopController`:
```swift
@available(*, deprecated, renamed: "amplitudeHistory")
public var scopeHistory: [Float] { amplitudeHistory }
```
This lets callers compile while you migrate them in subsequent tasks. Remove the alias at end of Phase 6.

- [ ] **Step 3: Run new AutoStop tests**

```bash
swift test --filter AutoStopControllerTests 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 4: Commit (with the temporary alias if you used it)**

```bash
git add Sources/HarcUI/AutoStopController.swift Tests/HarcUITests/AutoStopControllerTests.swift
git commit -m "$(cat <<'EOF'
refactor(autostop): scopeHistory → amplitudeHistory, capacity 40 → 96

24 Hz sampling (interval 1/24 s) over 96-frame ring buffer = ~4 s of
history for the new fluid-water viz. Silence detection signal unchanged
(it reads smoothedDb directly, not the visualization buffer). Temporary
deprecated alias kept on scopeHistory so downstream callers compile
during the rename cascade — alias deleted in Phase 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Bridge + AppDelegate rewires

### Task 5.1: Rename in `HarcAppBridge`

**Files:**
- Modify: `Sources/HarcUI/HarcAppBridge.swift`

- [ ] **Step 1: Apply the rename**

Find:
```swift
@Published public var scopeHistory: [Float] = []
```
Replace with:
```swift
@Published public var amplitudeHistory: [Float] = []
```

- [ ] **Step 2: Update `AppDelegate.swift`**

In `HarcApp/AppDelegate.swift`, find:
```swift
autoStop.$scopeHistory
    .receive(on: DispatchQueue.main)
    .assign(to: \.scopeHistory, on: bridge)
    .store(in: &cancellables)
```
Replace with:
```swift
autoStop.$amplitudeHistory
    .receive(on: DispatchQueue.main)
    .assign(to: \.amplitudeHistory, on: bridge)
    .store(in: &cancellables)
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: still failing on `MenuBarPanelView.swift` and `LiveScopeView.swift`. Continue.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/HarcAppBridge.swift HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
refactor(bridge): rename scopeHistory → amplitudeHistory

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Surface integration (icon, panel, pill) + delete old viz

### Task 6.1: Swap menu-bar icon and panel to LiveWaveformView

**Files:**
- Modify: `HarcApp/HarcApp.swift`
- Modify: `Sources/HarcUI/MenuBarPanelView.swift`

- [ ] **Step 1: Update `MenuBarPanelView.swift`**

Find the param + body:
```swift
let scopeHistory: [Float]
...
LiveScopeView(history: scopeHistory, tint: recordingState.isRecording ? .live : .dimmed)
```
Replace with:
```swift
let amplitudeHistory: [Float]
...
LiveWaveformView(
    history: amplitudeHistory,
    size: .panel,
    isActive: recordingState.isRecording
)
.frame(height: 28)
```

Update the init and any other references to `scopeHistory` in the file (parameter name, default value).

- [ ] **Step 2: Update `HarcApp.swift`**

Find the `MenuBarExtraLabel` body:
```swift
Image(systemName: "waveform")
    .foregroundStyle(bridge.recordingState.isRecording ? HarcBrand.live : .primary)
```
Replace with:
```swift
LiveWaveformView(
    history: bridge.amplitudeHistory,
    size: .icon,
    isActive: bridge.recordingState.isRecording
)
.frame(width: 22, height: 14)
```

Find `MenuBarExtraContent.body` where it constructs `MenuBarPanelView(...)`. Change `scopeHistory: bridge.scopeHistory` to `amplitudeHistory: bridge.amplitudeHistory`.

- [ ] **Step 3: Build + run**

```bash
swift build 2>&1 | tail -5
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -5
```

Both green.

- [ ] **Step 4: Commit**

```bash
git add HarcApp/HarcApp.swift Sources/HarcUI/MenuBarPanelView.swift
git commit -m "$(cat <<'EOF'
feat(menubar): icon + panel use LiveWaveformView

Menu bar icon swaps the SF Symbol placeholder for the .icon size of the
fluid-water viz, tinted with WavePalette while recording and freezing
when idle. Panel uses .panel size. amplitudeHistory plumbed through
from the bridge.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.2: Compound recording pill in main window toolbar

**Files:**
- Modify: `Sources/HarcUI/HarcWindowRootView.swift`
- Modify: `HarcApp/WindowControllers/HarcWindowController.swift`

- [ ] **Step 1: Add `amplitudeHistory` to `HarcWindowRootView` init**

Find the init signature in `HarcWindowRootView.swift`. Add a new parameter:
```swift
let amplitudeHistory: [Float]
```
Update `init(...)` to accept and store it. (Place after `recordingState`.)

- [ ] **Step 2: Replace the recording pill in the toolbar**

Find the existing pill in the `.toolbar` block (the leading `ToolbarItem` that renders when `recordingState.isRecording`):

Currently:
```swift
HStack(spacing: 6) {
    Circle().fill(HarcBrand.live).frame(width: 8, height: 8)
    Text("Recording").font(.subheadline).foregroundStyle(.white)
}
.padding(.horizontal, 10).padding(.vertical, 4)
.background(HarcBrand.live.opacity(0.7), in: Capsule())
.foregroundStyle(.white)
```

Replace with:
```swift
HStack(spacing: 8) {
    Circle()
        .fill(HarcBrand.live)
        .frame(width: 8, height: 8)
    LiveWaveformView(
        history: amplitudeHistory,
        size: .pill,
        isActive: true,
        tint: WavePalette.center
    )
    .frame(width: 60, height: 16)
    Text("Recording")
        .font(.subheadline)
        .foregroundStyle(.primary)
}
.padding(.horizontal, 10)
.padding(.vertical, 4)
.background(.regularMaterial, in: Capsule())
.overlay(Capsule().stroke(HarcBrand.live.opacity(0.4), lineWidth: 1))
```

- [ ] **Step 3: Plumb `amplitudeHistory` through `HarcWindowController`**

In `HarcApp/WindowControllers/HarcWindowController.swift`, find the `init` that constructs `HarcWindowRootView(...)`. Add an `amplitudeHistory: [Float]` init parameter and pass it through.

- [ ] **Step 4: Update the construction site in `AppDelegate`**

In `HarcApp/AppDelegate.swift`, find the `openLibrary()` (or equivalent) method that creates `HarcWindowController`. Pass `amplitudeHistory: bridge.amplitudeHistory`.

**Caveat:** `bridge.amplitudeHistory` is a `@Published` array. Passing it as a value at construction time means the window controller hosts a SwiftUI view with a stale snapshot — it won't refresh. To fix, the SwiftUI view should observe the bridge directly (or accept a binding). Two options:

  - **a.** Pass the entire `bridge` into `HarcWindowRootView` as `@ObservedObject` — the view reads `bridge.amplitudeHistory` directly. Simpler; matches how `MenuBarExtraContent` works.
  - **b.** Convert `amplitudeHistory: [Float]` to `amplitudeHistory: Binding<[Float]>` so updates propagate.

**Choose option (a).** Concretely: replace the `let amplitudeHistory: [Float]` from Step 1 with `@ObservedObject var bridge: HarcAppBridge`, and read `bridge.amplitudeHistory` at every use site within the toolbar. Update Step 3 to plumb `bridge` instead of `amplitudeHistory`.

Revised Step 1 declaration:
```swift
@ObservedObject var bridge: HarcAppBridge
```

Revised pill body line:
```swift
LiveWaveformView(
    history: bridge.amplitudeHistory,
    size: .pill,
    isActive: true,
    tint: WavePalette.center
)
```

Revised Step 3: pass `bridge: bridge` into `HarcWindowController`'s init, then `bridge: bridge` into `HarcWindowRootView`.

- [ ] **Step 5: Build + smoke**

```bash
swift build 2>&1 | tail -5
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -5
```

Both green.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/HarcWindowRootView.swift HarcApp/WindowControllers/HarcWindowController.swift HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(window): compound recording pill — red dot + LiveWaveformView

Pill background switches from solid red to glass with a red stroke;
red dot keeps the recording semantic, LiveWaveformView(.pill) shows
the actual audio activity. Drives off bridge.amplitudeHistory observed
via @ObservedObject so updates propagate live.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.3: Delete `LiveScopeView` and the deprecation alias

**Files:**
- Delete: `Sources/HarcUI/LiveScopeView.swift`
- Modify: `Sources/HarcUI/AutoStopController.swift` (remove the temporary alias from Task 4.2 if it was added)

- [ ] **Step 1: Confirm no remaining references**

```bash
grep -rn "LiveScopeView\|scopeHistory\|scopeBarInterval\|scopeBarCapacity" Sources/ HarcApp/ Tests/ 2>&1 | grep -v "LiveScopeView.swift"
```

Expected: zero matches. If any remain, fix them.

- [ ] **Step 2: Delete the file**

```bash
git rm Sources/HarcUI/LiveScopeView.swift
```

- [ ] **Step 3: Remove the deprecation alias in `AutoStopController.swift` (if added)**

Find:
```swift
@available(*, deprecated, renamed: "amplitudeHistory")
public var scopeHistory: [Float] { amplitudeHistory }
```
Delete it.

- [ ] **Step 4: Build, test, xcodebuild**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -3
```

All three green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(ui): delete LiveScopeView and the scopeHistory deprecation alias

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — Final QA + push

### Task 7.1: Manual smoke + size + final push

- [ ] **Step 1: Quit and rebuild the local distributable**

```bash
osascript -e 'tell application "Harc" to quit'
sleep 2
scripts/build-local.sh 2>&1 | tail -3
rm -rf /Applications/Harc.app
cp -R build/local-dist/Harc.app /Applications/Harc.app
xattr -dr com.apple.quarantine /Applications/Harc.app 2>/dev/null
open /Applications/Harc.app
```

- [ ] **Step 2: Run through the manual smoke checklist**

- [ ] Menu-bar icon shows the new fluid waveform (flat when idle, animated when recording)
- [ ] Open the panel — panel viz animates in lockstep with icon
- [ ] Open the main window — start recording from menu bar; toolbar pill shows red dot + blue waveform on glass
- [ ] Stop recording — all three live surfaces flatten and freeze within ~200 ms
- [ ] Select a finished recording in the sidebar — `StaticWaveformView` renders above the summary card within ~500 ms
- [ ] Switch between recordings rapidly — cache returns previously-decoded envelopes instantly; no flicker
- [ ] Flip System Appearance to Light — palette readable
- [ ] Flip back to Dark — palette readable

- [ ] **Step 3: Verify performance**

While recording, glance at Activity Monitor. Harc CPU should stay under 10% on M-series Macs (most of that being the daemon, not the UI). If the UI process spikes above 5% from viz alone, drop the timeline interval from 1/30 to 1/24 in `LiveWaveformView`.

- [ ] **Step 4: Module size check**

```bash
wc -l Sources/HarcUI/*.swift Sources/HarcUI/Settings/*.swift Sources/HarcUI/Inspector/*.swift Sources/HarcUI/TranscriptEditor/*.swift | tail -1
```

Note the total. Expected delta from this feature: roughly +400 LoC (three new view files + loader + tests) minus ~70 LoC (deleted LiveScopeView).

- [ ] **Step 5: Push**

```bash
git push 2>&1 | tail -3
```

The PR (#36) auto-updates with these new commits.

---

## Notes for the executing agent

- **Property/init names must match what already exists.** When in doubt, `grep` first.
- **The `amplitudeHistory` rename cascades through 5 files.** Use the temporary `scopeHistory` alias on `AutoStopController` (Task 4.2) to keep the build green during the cascade. Remove the alias in Task 6.3.
- **`HarcWindowRootView` should observe the bridge, not take a snapshot of `amplitudeHistory`.** Task 6.2 Step 4 explains this — option (a). Without it, the toolbar pill never updates.
- **No `--no-verify` on commits.** If a hook fails, fix the underlying issue.
- **Run `swift test` after each phase**, not just at the end. Catches drift early.
- **The `AmplitudeEnvelopeLoader` cache is process-local.** It does NOT persist envelopes to disk; first selection of any recording in a new app session re-decodes. This is intentional — disk caching is a future optimization.
