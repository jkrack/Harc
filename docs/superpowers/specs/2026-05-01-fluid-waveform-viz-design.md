# Fluid Waveform Visualization — Design Spec

**Date:** 2026-05-01
**Status:** Approved (brainstorming complete; awaiting plan)
**Owner:** J
**Branch:** TBD (extends `feat/native-ui-rebuild-2026-04-27` or follow-up)

## 1. Problem

The current audio visualization in Harc is a static 5-bar peak meter (`LiveScopeView`) that only appears in the menu-bar panel. It reads as a low-fidelity placeholder rather than an active, expressive part of the app's identity. We want a richer, kinetic visualization that:

- Reflects audio activity across all the surfaces where recording state is shown (menu-bar icon, panel, main-window toolbar pill).
- Renders finished recordings' amplitude envelopes in the detail view as a static visual.
- Reads as **fluid water in motion**, not a discrete bar meter — visually distinct from the brand-red recording chrome (the dot, the pill border) and locally palette'd in blue/cyan.

## 2. Goals

- Replace the 5-sample peak meter with a 96-sample rolling time-series amplitude buffer that scrolls naturally.
- Render with a fluid water aesthetic: 2 mirrored bezier wave layers, slow phase drift, blue→cyan vertical gradient, light cyan highlight stroke.
- Three live size variants (`.icon`, `.panel`, `.pill`) sharing one rendering component (`LiveWaveformView`).
- A static detail-view component (`StaticWaveformView`) that renders a finished WAV's amplitude envelope.
- Idle (not recording) freezes the live viz to a flat line — recording state stays unambiguous.
- Compound recording pill in the main-window toolbar: red dot (semantic) + blue waveform (aliveness) inside a single glass capsule.

## 3. Non-goals

- Frequency spectrum analyzer. Considered but cut: the Shutterstock reference and the user's "fluid water moving across the screen" framing both fit time-series scroll, not frequency-domain rendering.
- Ambient motion when idle. Cut: ambiguity about "is recording happening?" is unacceptable.
- Audio playback or scrubbing inside `StaticWaveformView`. The detail view is read-only; playback lives in `TranscriptEditor`.
- Stereo split, per-band coloring, or per-frequency tinting. Recording is mono per project conventions.
- Adding the viz palette to `HarcBrand`. The brand sliver stays minimal; viz palette is local.

## 4. Hard decisions made during brainstorming

| Decision | Choice |
|---|---|
| Surfaces in scope | All four: menu-bar icon, menu-bar panel, main-window toolbar pill, detail-view static waveform. |
| Visual style | Fluid water (continuous bezier layers + soft gradient), not discrete bars; not literal frequency spectrum. |
| Palette | Blue/cyan (`#1B4F8C` center → `#5CD2FF` edge), light cyan highlight. Local to viz files. |
| Recording pill treatment | Compound: red dot + blue waveform in one glass capsule (Section 2c). |
| Detail-view interaction | Display only — no scrub, no playback. |
| Data source | Time-series amplitude history (rename + extend existing `scopeHistory`), not new FFT aggregation. |
| Idle behavior | Freeze flat. No ambient motion. |
| `scopeHistory` legacy | Replaced outright by `amplitudeHistory`. Silence detection uses an unrelated signal; no compatibility concern. |

## 5. Components & data flow

```
                 ┌─────────────────────┐
 mic + sysaudio  │ AutoStopController  │   exposes:
 ────────────▶  │   (existing)        │   - amplitudeHistory: [Float]
                 │   amplitudeHistory  │     (length 96, ~24 Hz, ~4s window)
                 └──────────┬──────────┘
                            │ @Published, forwarded to bridge
                            ▼
                 ┌─────────────────────┐
                 │   HarcAppBridge     │
                 │   .amplitudeHistory │
                 └──────────┬──────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
    LiveWaveformView  LiveWaveformView  LiveWaveformView
       (.icon)           (.panel)         (.pill)
    in MenuBarExtra   in MenuBarPanel   in HarcWindow
       label             body            toolbar pill


    finished WAV on disk
            │
            ▼
    AmplitudeEnvelopeLoader.load(url:, samples: 1024) → [Float]
            │
            ▼
    StaticWaveformView(envelope: [Float])
       in HarcWindowRootView detail pane
```

### New types

- **`LiveWaveformView`** (`Sources/HarcUI/LiveWaveformView.swift`)
  - `init(history: [Float], size: Size, isActive: Bool, tint: Color = WavePalette.center)`
  - `enum Size { case icon, panel, pill }`
  - "Dumb" renderer driven by parent re-renders. Reads `history` by value.

- **`StaticWaveformView`** (`Sources/HarcUI/StaticWaveformView.swift`)
  - `init(envelope: [Float], tint: Color = WavePalette.center)`
  - Frozen mirror-of-amplitude render, no animation.

- **`AmplitudeEnvelopeLoader`** (`Sources/HarcUI/AmplitudeEnvelopeLoader.swift`)
  - `static func load(url: URL, samples: Int = 1024) async throws -> [Float]`
  - 16 kHz mono Int16 WAV → normalized peak amplitudes per chunk.
  - LRU cache, capped at 16 entries.
  - Off-main-actor.

- **`WavePalette`** (`Sources/HarcUI/WavePalette.swift`)
  - `static let center: Color` (deep blue `#1B4F8C`)
  - `static let edge: Color` (cyan `#5CD2FF`)
  - `static let stroke: Color` (light cyan highlight)
  - Light-mode variants via `Color(light:dark:)` initializer if contrast manual-QA reveals issues.

### Removed / renamed

- `Sources/HarcUI/LiveScopeView.swift` — **deleted.**
- `AutoStopController.scopeHistory` — **renamed** to `amplitudeHistory`. Capacity 5→96. Interval 0.2s→0.04s. Pre-filled with zeros. Unchanged silence-detection semantics.
- `HarcAppBridge.scopeHistory` — **renamed** to `amplitudeHistory`.
- All Combine forwarding sinks renamed accordingly.

## 6. Rendering specifics

### Live (`LiveWaveformView`)

Per-frame render via SwiftUI `Canvas`:

1. **Smoothing** — `@State var displayedHistory: [Float]` interpolates toward incoming `history` at ~7%/frame (slow exponential low-pass; water swells, doesn't snap).
2. **Two stacked wave layers** — each is a filled mirrored-around-center path, drawn through the displayed history values with bezier (Catmull-Rom or quad-bezier) smoothing. Bars-of-amplitude become a continuous shape.
3. **Phase drift** — each layer has its own slow horizontal phase offset (~0.3 Hz and ~0.5 Hz, opposed). Implemented as `TimelineView(.animation)` driving a sin-modulated x-offset on each path. Only fires when `isActive == true`.
4. **Fill** — vertical `LinearGradient` from `WavePalette.center` (centerline) to `WavePalette.edge` (peaks), with edge alpha falling toward 0 at the outer-most extents.
5. **Stroke (top layer only)** — 1pt `WavePalette.stroke`, catches "light" on the water surface.
6. **Idle** — `isActive == false` collapses the displayed values to zero. Phase drift halts. Renders a single soft blue horizontal line.

### Live size variants

| Size      | Height | Sample-to-pixel mapping | Phase amplitude |
|-----------|--------|------------------------|-----------------|
| `.icon`   | 14pt   | downsample to 32 visual points | 0.4pt |
| `.panel`  | 28pt   | full 96 samples → ~3pt per sample at 280pt panel width | 0.8pt |
| `.pill`   | 16pt   | downsample to 48 visual points | 0.6pt |

### Static (`StaticWaveformView`)

- Single filled mirrored shape using `WavePalette.center` at `0.7` opacity (reads as completed-state, not active-state).
- No animation, no second layer, no stroke overlay, no phase drift.
- One-time fade-in when `envelope` first becomes non-empty (≤200 ms `.transition(.opacity)`).
- Default frame: 40pt height, full width of detail pane.
- Where: top of detail pane, above `SummaryCardView`.

## 7. Surface integration

### Menu-bar icon (`HarcApp/HarcApp.swift`)

Replace the `Image(systemName: "waveform")` placeholder in `MenuBarExtraLabel` with:
```swift
LiveWaveformView(
    history: bridge.amplitudeHistory,
    size: .icon,
    isActive: bridge.recordingState.isRecording
)
```

### Menu-bar panel (`Sources/HarcUI/MenuBarPanelView.swift`)

Rename the `scopeHistory` parameter to `amplitudeHistory`. Replace the `LiveScopeView(history:tint:)` call site with:
```swift
LiveWaveformView(
    history: amplitudeHistory,
    size: .panel,
    isActive: recordingState.isRecording
)
.frame(height: 28)
```

### Main-window toolbar pill (`Sources/HarcUI/HarcWindowRootView.swift`)

Extend the view's init to accept `amplitudeHistory: [Float]`. Plumb it through `HarcWindowController` from `bridge.amplitudeHistory`. Replace the existing red-capsule pill with the compound shape:

```swift
HStack(spacing: 8) {
    Circle().fill(HarcBrand.live).frame(width: 8, height: 8)
    LiveWaveformView(
        history: amplitudeHistory,
        size: .pill,
        isActive: true,
        tint: .white
    )
    .frame(width: 60, height: 16)
    Text("Recording").font(.subheadline).foregroundStyle(.white)
}
.padding(.horizontal, 10).padding(.vertical, 4)
.background(.regularMaterial, in: Capsule())
.overlay(Capsule().stroke(HarcBrand.live.opacity(0.4), lineWidth: 1))
```

### Detail-view static waveform (`Sources/HarcUI/HarcWindowRootView.swift`)

Add `@State private var detailEnvelope: [Float] = []` to the view. Hook envelope loading to `selection` change (parallel to existing `loadTranscript()`):
```swift
.onChange(of: selection) { _, _ in
    loadTranscript()
    Task { await loadEnvelope() }
}

private func loadEnvelope() async {
    guard let rec = currentRecording else { detailEnvelope = []; return }
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

In the detail VStack, above `SummaryCardView`:
```swift
StaticWaveformView(envelope: detailEnvelope)
    .frame(height: 40)
    .padding(.horizontal)
```

## 8. Files touched

| File | Change |
|---|---|
| `Sources/HarcUI/AutoStopController.swift` | Rename `scopeHistory` → `amplitudeHistory`. Capacity 5→96. Interval 0.2s→0.04s. Pre-fill zeros. |
| `Sources/HarcUI/HarcAppBridge.swift` | Rename `scopeHistory` → `amplitudeHistory`. |
| `HarcApp/AppDelegate.swift` | Rename Combine forwarding sink. |
| `HarcApp/HarcApp.swift` | `MenuBarExtraLabel` swaps to `LiveWaveformView(.icon)`. `MenuBarExtraContent` passes `bridge.amplitudeHistory` to `MenuBarPanelView`. |
| `Sources/HarcUI/MenuBarPanelView.swift` | Replace `LiveScopeView` call with `LiveWaveformView(.panel)`. Rename param. |
| `Sources/HarcUI/HarcWindowRootView.swift` | Add `amplitudeHistory` init param. Rewrite recording pill (Section 2c). Add `StaticWaveformView` + envelope loading at top of detail. |
| `HarcApp/WindowControllers/HarcWindowController.swift` | Plumb `amplitudeHistory` from bridge. |
| `Sources/HarcUI/LiveScopeView.swift` | **Deleted.** |
| `Sources/HarcUI/LiveWaveformView.swift` | **New.** Section 6 fluid-water rendering. |
| `Sources/HarcUI/StaticWaveformView.swift` | **New.** Frozen counterpart. |
| `Sources/HarcUI/AmplitudeEnvelopeLoader.swift` | **New.** WAV → `[Float]` envelope loader with LRU cache. |
| `Sources/HarcUI/WavePalette.swift` | **New.** Local viz palette. |
| `Tests/HarcUITests/AutoStopControllerTests.swift` | Extend with `amplitudeHistory` rolling + capacity tests. |
| `Tests/HarcUITests/AmplitudeEnvelopeLoaderTests.swift` | **New.** Load fixture, cache hit, length, range. |

## 9. Testing

**Unit tests** (Swift Testing):

- `AutoStopController.amplitudeHistory` length is exactly 96.
- Incoming amplitudes scroll: oldest dropped, newest appended.
- Idle pushes zero samples.
- `AmplitudeEnvelopeLoader` returns array of requested length, all values in `[0, 1]`, peaks correlate with speech regions of the fixture WAV (`short-speech.wav`).
- `AmplitudeEnvelopeLoader` cache: two calls with the same `(url, samples)` return identical results without re-decoding.

**Visual / not unit-tested:**

- `LiveWaveformView` rendering at each size — Xcode previews + manual inspection.
- `StaticWaveformView` rendering — preview + manual.

**Manual integration smoke:**

- Start a recording → menu-bar icon, panel viz, and toolbar pill all animate in lockstep.
- Stop → all three flatten and freeze within ~200 ms.
- Open a finished recording in the detail view → static waveform appears within ~500 ms.
- Switch between recordings rapidly → cache returns previously-loaded envelopes instantly; no flicker.
- System Appearance → Light: palette readable. Dark: palette readable.

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | 24 Hz Combine emit on the main thread feels heavy under load | Profile during a real recording. If laggy, drop emit rate to 12 Hz; per-frame view interpolation preserves visual smoothness. |
| 2 | Bezier path through 96 points re-rendered at 24 Hz could spike GPU on older M1s | Canvas is GPU-accelerated; budget should stay under 1% on M1. If issue arises, reduce to 64 points. |
| 3 | `AmplitudeEnvelopeLoader` blocks on huge WAVs (multi-hour) | Stream-read in 1 MB chunks; never load entire WAV into memory. Per-chunk peak extraction is O(chunk). |
| 4 | LRU cache leaks if user opens hundreds of recordings | Cap at 16 entries (~64 KB total). LRU eviction. |
| 5 | Renaming `scopeHistory` may touch tests referencing the old name | Search-and-replace; update existing AutoStopController tests in the same commit. |
| 6 | 24 Hz parent re-renders could cause SwiftUI diffing overhead | Each consumer is already a tight observer (`MenuBarExtraLabel` only observes `bridge`). Viz reads `[Float]` by value; SwiftUI's diff is cheap on small leaves. |
| 7 | Pill rewrite may look busy on narrow toolbars | Manual QA. If too cramped, drop "Recording" text and keep dot + waveform only. |
| 8 | Palette may not work in light mode (low contrast on white) | Manual QA in light mode. Use `Color(light:dark:)` to provide both variants if needed. |

## 11. Things explicitly cut

- Frequency spectrum analyzer rendering. Time-series scroll fits "fluid water moving across screen" cleanly.
- Detail-view audio playback (lives in `TranscriptEditor`).
- Idle ambient motion (clarity over decoration).
- Per-band coloring or stereo split.
- Adding viz palette to `HarcBrand` (kept local to viz files).

## 12. Things explicitly preserved

- `HarcBrand.live` red as the "recording" semantic (menu-bar dot, toolbar pill dot, capsule stroke).
- `AutoStopController` silence detection — uses an independent signal (`smoothedDb` vs. `silenceDbCeiling`); the visualization buffer change does not affect it.
- All other Harc behavior — daemon, store, summarizer, hotkeys, recording pipeline.

## 13. Success criteria

1. `swift test` and `xcodebuild` both green.
2. New tests for `AutoStopController.amplitudeHistory` and `AmplitudeEnvelopeLoader` pass.
3. Manual smoke: recording produces visibly synchronized motion across menu-bar icon, panel, and toolbar pill. Stop freezes all three.
4. Detail view shows the recorded waveform within ~500 ms of selection on a typical 30-min recording.
5. Light-mode and Dark-mode palettes both readable.
6. No measurable performance regression vs. the current 5-bar implementation (frame time within 1 ms of baseline during recording).
