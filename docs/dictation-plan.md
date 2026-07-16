# Harc Dictation — Implementation Plan

Goal: mirror the **local** capabilities of [SuperWhisper](https://superwhisper.com/docs/get-started/introduction)
— hotkey dictation, insert-at-cursor, AI post-processing "modes", context
awareness — **augmenting** Harc's meeting recorder rather than replacing it.

## Scope decisions (locked)

- **Augment, not pivot.** Dictation is a second surface alongside meeting capture. The meeting flow is untouched.
- **English-only.** Keep Parakeet TDT. We do **not** mirror SuperWhisper's 100+ languages (hard constraint in `CLAUDE.md`).
- **Local only.** No cloud STT/LLM, no user API keys. macOS only.

Non-goals: multilingual/translation, cloud models, iOS/Windows, real-time streaming token output.

## The reuse win

Four probes of the current code show most of the engine already exists:

| Need | Status | Anchor |
|---|---|---|
| Fast short-clip STT | **Exists** — `transcribe(diarize:false, vad:false)` auto-skips VAD (≤30s bypass) + diarization; warm Parakeet resident | `HarcClient/HarcSTTClient.swift:48`, `HarcSTT/Transcriber.swift:120` |
| Second hotkey + push-to-talk | **Trivial** — add a `KeyboardShortcuts.Name`, wire `onKeyDown`/`onKeyUp` | `HarcUI/HotkeyNames.swift:4`, `AppDelegate.swift:241` |
| Mic capture (mic-only, no ScreenCaptureKit) | **Reuse** `MicCapture` + `AudioFileWriter` | `HarcAudio/MicCapture.swift:19`, `AudioFileWriter.swift` |
| Insert at cursor in any app | **Reuse** `FrontmostAppPaster` (pasteboard + synthetic Cmd-V) + Accessibility perm | `HarcUI/FrontmostAppPaster.swift:35` |
| Target guards (deny-list, frontmost) | **Reuse** `PasteDenyList` / `AutoPasteGuard` | `HarcUI/PasteDenyList.swift`, `AutoPasteDecision.swift:21` |
| LLM post-processing | **Reuse** `SummarizerService` warm container; add one `transform()` method | `HarcSummarize/SummarizerService.swift:154` (`answer` is the template), `ContainerLike.swift:17` |
| Model management / pick a model | **Reuse** `ModelManager.requireInstalled`, `ModelCatalog` (4 Gemma tiers) | `HarcModels/ModelManager.swift:105` |

Genuinely net-new: (1) the push-to-talk capture controller, (2) the modes data model + store + UI, (3) Super-Mode context capture (AX selected text + clipboard), (4) file-import UI.

## Cross-cutting constraints

- **Mutual exclusion.** Dictation and meeting recording share the mic (`AVAudioEngine`) and the `harc-stt` daemon. Dictation must refuse to start while `RecordingState.isRecording`, and vice-versa. Mirror the `bridge.recordingStopInFlight` in-flight guard idiom.
- **Keep-warm.** Daemon idle-shutdown is 30 min (`Daemon.swift:14`). For instant dictation, either raise the idle timeout or have the dictation controller ping `client.status()` to reset `lastActivity`. Decision: opt-in "keep dictation instant" that pings while the app is frontmost/recently used.
- **Model thrash.** `SummarizerService` holds ONE resident container and reloads on model-id change. If a mode uses a different model than the active summarizer, they thrash-reload (multi-GB). Default a mode's model to `prefs.activeSummarizerID` and share the single `SummarizerService` instance.
- **Latency budget (Phase 1 target).** Warm path = mic stop → resample+Parakeet (short clip) → paste. Target < ~1s for a sentence. LLM modes add model inference time (keep off the FIFO `SummarizationQueue` so dictation never waits behind a meeting summary).

---

## UI surfaces & design

Native macOS 26 SwiftUI, Liquid Glass (`.glassEffect()`), system materials/fonts,
`Color.accentColor` + `HarcBrand.live` for the recording state — no custom design
system (per `CLAUDE.md`). We mirror SuperWhisper's surfaces in this idiom.

### 1. Dictation HUD — floating recording window (headline new surface)

Mirrors SuperWhisper's recording window (mini ↔ expanded). This is the biggest net-new UI.

- **Window type:** an AppKit `NSPanel` (`.nonactivatingPanel` + borderless, `.floating`
  level) hosting a SwiftUI view via `NSHostingView`, styled with `.glassEffect()`.
  **Critical:** it must be *non-activating* — dictation inserts into the frontmost app via
  synthetic Cmd-V (`FrontmostAppPaster`), so the HUD must never steal focus. (The app already
  uses AppKit windowing — `NSStatusItem`/`NSPopover`, not `MenuBarExtra` — so an `NSPanel` fits.)
- **Position:** bottom-center above the Dock by default (SuperWhisper's default), user-configurable
  (near-cursor option). Appears on dictation start; auto-dismisses shortly after insert.
- **Two views, hover resize toggle:**
  - **Mini/pill:** compact glass capsule — live waveform + status dot + stop. Optionally persistent.
  - **Expanded:** waveform + status text + active-mode chip + context indicator + stop + cancel.
- **Live waveform:** reuse the **scope FFT already threaded through `HarcAppBridge`** (the same
  signal the menu-bar level bars use) — no new DSP.
- **Status dot** (maps to `DictationState`): amber = model loading, `HarcBrand.live` = listening,
  accent/blue = transcribing, green = done. (Mirrors SW's yellow/blue/green.)
- **Mode chip:** active mode name + hotkey; click opens the mode switcher. In Super Mode, shows the
  captured app/website context.
- **Context-capture indicator:** lights when selected-text/clipboard context is captured (Phase 3).
- **Stop / Cancel:** stop = same hotkey that started; cancel discards (confirm if session > 30s, mirroring SW).

### 2. Menu-bar panel additions

- Dictation pill/section in `MenuBarPanelView` near the Record/Stop row (`:150`): current mode,
  start-dictation control, dictation readiness. Right-click the status item → quick mode switch +
  recent-dictation history (mirrors SW's mini-window right-click menu).

### 3. Mode switcher

- Lightweight keyboard-navigable popover (icon + name + hotkey per mode), reachable from the HUD mode
  chip and the menu-bar panel.

### 4. Settings — new "Dictation" + "Modes" panes

- **Dictation:** hotkey recorder, HUD position/default view (mini vs expanded), keep-warm toggle,
  insertion behavior (paste vs copy-only), mutual-exclusion note.
- **Modes:** list + create/edit — name, icon, instruction/prompt, model picker (Gemma tiers),
  STT options, per-mode context toggles, optional per-mode hotkey, inline test-run.

### 5. Dictation history (Phase 5)

- Recent dictations (text + mode + timestamp) with re-copy / re-insert — either a "Dictation" section
  in the library window or a menu-bar history popover.

### 6. Onboarding & readiness

- Request **Accessibility** up-front in `WelcomeFlowView` (today it's lazy on first paste) and add a
  **dictation readiness row** to `LocalStackHealth`.

**UI-by-phase:** Phase 1 ships the **mini HUD** (waveform + status dot + stop) and the menu-bar pill.
Phase 2 adds the **mode chip + switcher + Modes settings**. Phase 3 adds the **context indicator**.
Phase 5 adds **history + onboarding**.

---

## Phase 1 — Dictation capture loop (MVP: raw push-to-talk)

Outcome: hold hotkey → speak → release → transcribed text inserted at cursor. No modes yet (raw transcript).

1. **Hotkey** — add `static let pushToTalkDictation = Self("harc.dictation")` to `HotkeyNames.swift`; register `onKeyDown`(start) + `onKeyUp`(stop) near `AppDelegate.swift:241`. Also support a toggle fallback for accessibility.
2. **`DictationController`** (new, in HarcUI to start — see module note): owns a lightweight capture using `MicCapture` alone (no `SystemAudioCapture`), writing a temp WAV via `AudioFileWriter` to `~/Library/Caches/Harc/dictation/<uuid>.wav`.
3. **Transcribe** — add `HarcSTTClient.dictate(audioPath:)` wrapper: `diarize:false, vad:false, wantTimestamps:false`, tighter timeout than the 60s `transcribeTimeout`. Ensure daemon warm via `launcher.ensureRunning()`.
4. **Insert** — on result, `FrontmostAppPaster.copyAndPaste(text)` after re-reading frontmost bundle id; run it through `AutoPasteGuard`/`PasteDenyList` first.
5. **State** — new `DictationState` (`@MainActor ObservableObject`: `.idle/.listening/.transcribing`), exposed on `HarcAppBridge`. Mutual-exclusion guard against `state.isRecording`.
6. **Menu-bar indicator** — dictation pill in `MenuBarPanelView` near the Record/Stop row (`:150`) / status header (`:216`); mic-glow on the status item.
7. **Settings** — a `KeyboardShortcuts.Recorder` for the dictation hotkey in `RecordingSettingsView.swift:97`.

Tests: `DictationController` state transitions; mutual-exclusion guard; `dictate()` request shape; deny-list gating.

## Phase 2 — Modes engine (AI post-processing)

Outcome: a picker of modes (Raw, Clean-up, Email, Bullet List, …) that reformat the transcript via the local LLM before insertion.

1. **`DictationMode` model** — `id`, `name`, `icon`, optional per-mode hotkey, STT options, `postProcess: .none | .llm`, `modelID` (default `activeSummarizerID`), `instruction` (prompt), `systemPrompt`, formatting hints.
2. **Built-in modes** — Raw (transcription only), Clean-up (strip filler/ums, fix punctuation/caps), Email, Message, Bullet List, Code comment. Seeded, user-editable.
3. **`ModeStore`** — persist modes (GRDB table in `HarcStore`, or JSON in Application Support). Active-mode selection in `HarcPreferences`.
4. **`ModeTransformPrompt`** — pure enum mirroring `ConversationPrompt`, `build(instruction:transcript:)`.
5. **`SummarizerService.transform(text:instruction:systemPrompt:modelID:modelDirectory:maxTokens:)`** — sibling to `answer` (`SummarizerService.swift:154`); reuses `getOrLoad` warm cache. ~15 lines.
6. **Pipeline** — `DictationController` routes transcript → active mode → (if `.llm`) `transform()` → insert. Run directly on the actor (serialized), NOT via `SummarizationQueue`.
7. **UI** — mode picker in the menu-bar panel; Modes settings pane (list, create/edit prompt, pick model, assign hotkey, test-run).

Tests: prompt builder output; `transform()` returns raw string; mode routing; store round-trip.

## Phase 3 — Super Mode (context awareness)

Outcome: a mode can read the user's selected text + clipboard + active app and feed them to the LLM.

1. **Context capture** (net-new) — `AXUIElementCopyAttributeValue` for `kAXSelectedTextAttribute` on the focused element; read `NSPasteboard.general.string`; frontmost app name (already available at `AppDelegate.swift:479`). Reuses the Accessibility permission already gated in `FrontmostAppPaster`.
2. **Prompt injection** — extend `ModeTransformPrompt` to optionally include a context block; per-mode toggles for which context to include.
3. **Privacy** — context capture is opt-in per mode; never leaves the device (local LLM). Respect `PasteDenyList` targets.

Tests: AX selected-text reader (mockable); context assembly; opt-in gating.

**Phase 3 status:** foundation built — `DictationContext` (`Sources/HarcUI/DictationContext.swift`, value type + `promptBlock` markdown rendering with per-field 4000-char truncation) and `SelectionContextReader` (`Sources/HarcUI/SelectionContextReader.swift`, `@MainActor capture(selectedText:clipboard:)` reading AX selected text / clipboard / frontmost app behind an injectable `Environment` seam; never prompts for Accessibility — untrusted just yields nil selection). Covered by `Tests/HarcUITests/DictationContextTests.swift` + `SelectionContextReaderTests.swift`. Remaining: per-mode context toggles, `ModeTransformPrompt` context-block injection, and the HUD context-capture indicator — those live on the modes-engine surfaces (`DictationMode*`, `DictationController`, HUD, Settings).

## Phase 4 — File / audio-video import transcription

Outcome: drop an audio/video file → transcribe → into the library (and optionally a mode transform).

- Import picker → copy/normalize to WAV → `HarcSTTClient.transcribe` (full, with diarization for long files) → library row. Largely reuses existing recording→library plumbing; mostly UI + an import path.

## Phase 5 — Polish

- Per-mode global hotkeys (each mode its own `KeyboardShortcuts.Name`).
- Dictation history (dictations as lightweight library entries or a separate list).
- Onboarding: request Accessibility up-front in `WelcomeFlowView` (today it's lazy on first paste); add a dictation readiness row to `LocalStackHealth`.
- Mode import/export (share a mode as JSON).

---

## Module placement (design note)

To start, `DictationController` + `DictationState` live in **HarcUI** (alongside `RecordingState`, `FrontmostAppPaster`, the bridge) to avoid a circular dependency, since `FrontmostAppPaster` lives in HarcUI. If dictation grows, extract a `HarcDictation` module — which requires first moving `FrontmostAppPaster`/`PasteDenyList`/`AutoPasteGuard` down into a shared lower module. Deferred until Phase 2+.

## Suggested sequencing

Phase 1 is a self-contained, shippable increment (raw push-to-talk dictation) and de-risks the whole thing. Ship it, then layer modes (Phase 2 — the SuperWhisper differentiator), then Super Mode (Phase 3). Phases 4–5 are independent and can slot in anytime.
