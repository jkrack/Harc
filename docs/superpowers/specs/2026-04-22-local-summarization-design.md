# Local Summarization (Gemma 4 via MLX) Design Doc

**Feature:** After a recording finishes, generate a structured summary + action items from the transcript using a locally-installed Gemma 4 model via MLX. Stored on the recording, shown in the Library detail pane, included in the Copy-for-Prompt blob. Opt-in, never blocks the recording pipeline, always deferrable.
**Date:** 2026-04-22
**Status:** draft — ready for implementation
**Depends on:** `2026-04-22-model-manager-design.md` (Gemma 4 weights + install UX)

---

## 1. Problem & user story

The current flow — "record → transcribe → paste into an LLM" — assumes the user pastes. For the most common meeting-capture use case the LLM work is always the same: summarize decisions, extract action items, identify themes. Doing that automatically, locally, is the obvious next step. The hard parts are social, not technical:

- **Never in the moment.** Summarization must not add 30 s to the "stop recording" gesture. The user just left a meeting; give them back their cursor. Run summary in a detached queue.
- **Never hidden cost.** Big local models use RAM and battery. Gemma 4 Max on a laptop on battery is a bad default.
- **Never a dead UI.** The detail pane shouldn't render an empty "Summary" card and leave the user guessing — missing summaries are explicitly "not generated yet" with a one-click trigger.

**User story (automatic).** "I stop an hour-long meeting. Harc transcribes in the background like always. A minute or two later, the library row for that meeting shows a 3-sentence summary and 4 action items. I didn't lift a finger."

**User story (manual).** "I open an old recording that was transcribed before I installed Gemma. The detail pane has a **Generate summary** button. I click, wait ~30 s, get the same card."

**User story (retry with bigger model).** "I installed Max after trying Standard and want to re-run summary for some recordings. In the detail pane the Summary header shows `generated with · Standard`. I click the ↻ next to it; it picks the current active model (Max) and re-generates."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new `HarcSummarize` Swift target that owns:
  - `SummarizerService` actor — loads the selected Gemma 4 model via mlx-swift on first use, caches it, serves sequential summarization requests.
  - `SummaryPrompt` — builds the prompt from a transcript (template + rendering helpers).
  - `SummaryOutput` — plain data struct with `summary: String` (markdown), `actionItems: [ActionItem]`, `model: String` (descriptor id), `generatedAt: Date`, `elapsedMs: Int`.
- Three new columns on `recordings`: `summary_markdown TEXT NULL`, `action_items_markdown TEXT NULL`, `summary_model_id TEXT NULL`, `summary_generated_at INTEGER NULL` (Unix ms). One `DatabaseMigrator` migration `v6_summary`.
- `RecordingStore.updateSummary(id:, output:)` / `.clearSummary(id:)` wires.
- `SummarizationQueue` (serial, `DispatchQueue` or `Task.detached` pipeline) that consumes a channel of recording IDs. Only one summary runs at a time — RAM usage of a loaded LLM is non-trivial.
- Automatic trigger at end of `AppDelegate.stopRecording` — after the transcript is persisted and the recording row is upserted, enqueue the ID. Trigger is gated by:
  - `HarcPreferences.autoSummarizeEnabled` (default `true`)
  - `HarcPreferences.autoSummarizeOnBatteryEnabled` (default `false`)
  - `prefs.activeSummarizerID` is installed via `ModelManager.state(of:) == .installed`
- `SummaryCardView` in `TranscriptionDetailView`:
  - Shows the summary + checkboxed action items when present.
  - Shows `Generate summary` CTA when `summary_markdown IS NULL`.
  - Shows a progress row (title, spinner, `Cancel`) while the recording is in the queue.
  - Shows `regenerate` affordance + `clear` affordance in an overflow menu.
- `ExportService.promptString(for:)` gains an optional leading `## Summary` + `## Action Items` block when available, sitting above the transcript. Gated by a Copy-for-Prompt preference `includeSummaryInPrompt` (default `true`).
- Unit tests for the prompt builder (snapshot), the parser that splits Gemma's output into summary + action items, `updateSummary` round-trip, queue serialization, and `promptString` threading.

**Out of scope / non-goals (v1):**

- **Streaming summary during recording.** We don't transcribe chunks through the LLM live. The summary runs once, on the final transcript, after the recording ends.
- **Custom prompts.** The template is fixed and internal. No "you are a helpful assistant" knob. (The one preference is the chosen tier, via Model Manager.)
- **Multi-turn chat over a transcript.** The summary is one-shot; conversational follow-up ("why did Jason push back on pricing?") is the paste-into-real-LLM workflow. Not a goal.
- **Cross-recording summarization.** "Summarize everything I did this week" is a future; v1 is per-recording.
- **Transcripts longer than the model's context.** Gemma 4 E2B/E4B ship with a bounded context; we cap the transcript at ~75 % of the context in tokens (see §6.2) and truncate gracefully. No sliding-window recursive summarization in v1.
- **Non-English.** Parakeet is English-only, so transcripts are English. Gemma is multilingual, but the prompt template and action-item parser assume English.
- **Editing the summary in place.** It's a generated artifact; users can regenerate but not edit. Hand-edits are a future (stored alongside the machine summary with a flag).
- **Background downloads.** Covered in Model Manager — summarization never kicks off a download on its own.

---

## 3. Dependencies & tooling

Add to `Package.swift`:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0"),
.package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "1.19.0"),
```

Targets:

```swift
.target(
    name: "HarcSummarize",
    dependencies: [
        "HarcCore",
        "HarcStore",
        "HarcModels",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-examples"),
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    ]
),
.testTarget(
    name: "HarcSummarizeTests",
    dependencies: ["HarcSummarize", "HarcCore", "HarcStore"]
),
```

`HarcUI` gains a dep on `HarcSummarize` (needed for the card) and a new env-object `SummarizerService`.

**Pinned versions will need verification** against the latest mlx-swift-examples API at implementation time — MLXLLM's loader API has moved in 2026-Q1. Treat the version numbers as placeholders.

---

## 4. Pipeline

### 4.1 Trigger

Concretely, at the tail of `AppDelegate.stopRecording(autoStopReason:)` after the existing `runAutoPaste(for:shiftHeld:)` call:

```swift
if prefs.autoSummarizeEnabled,
   shouldSummarizeGivenPower(),                           // honors autoSummarizeOnBatteryEnabled
   ModelManager.shared.state(of: prefs.activeSummarizerID) == .installed,
   let id = rec.id {
    await summarizationQueue.enqueue(recordingID: id)
}
```

`shouldSummarizeGivenPower()` reads `IOPSCopyPowerSourcesInfo` — if on battery AND `autoSummarizeOnBatteryEnabled == false`, skip. The summary gets enqueued next time the user opens the detail pane of an un-summarized recording, or they can click Generate manually.

### 4.2 Queue semantics

- A single `SummarizationQueue` actor. Holds `pending: [Int64]` of recording IDs, a `current: Int64?`, and a continuation back to the Service.
- At most one LLM request at a time. The LLM is memory-hungry; serializing by design.
- If the same ID is enqueued twice, dedupe on insert.
- Cancellation: enqueuing a `cancel(id:)` removes a pending entry, or if it's `current`, aborts the generation via the LLM's cancellation token.
- The queue persists across tray re-renders via a single shared instance on AppDelegate. Survives popover open/close. Resets on app quit (no disk persistence — next launch just re-enqueues what's un-summarized).

### 4.3 SummarizerService

```swift
public actor SummarizerService {
    private var loadedModelID: String?
    private var llm: LLMModelContainer?    // from MLXLLM

    public func summarize(
        transcript: String,
        modelID: String,
        cancellation: CancellationToken
    ) async throws -> SummaryOutput

    /// Unload — called when switching active models or on memory pressure.
    public func unload()
}
```

- First call with a given `modelID` loads the model from `~/Library/Application Support/Harc/Models/<id>/` via `MLXLLM`. Subsequent calls with the same id reuse the container.
- Generation via `MLXLLM`'s async token stream; aggregate into a string; then split into summary + action items with the parser in §5.3.
- On cancellation, drain the stream early and throw `CancellationError`.

### 4.4 Memory pressure

- On `NSWorkspace.didActivateApplicationNotification` for a heavyweight app (Chrome, Final Cut), or on explicit memory pressure from `DispatchSource.makeMemoryPressureSource(...)`, call `SummarizerService.unload()` to free the resident model. Next summary pays the load cost again.
- The LLM is idle between summaries but still resident. A future `unloadAfterIdleSeconds` setting could trim this; v1 keeps it loaded for the app lifetime once first used.

---

## 5. Prompt + parser

### 5.1 Template

One hardcoded template, English, markdown-only.

```
You analyze meeting transcripts and produce a short, factual summary plus
action items.

Output EXACTLY this format:

## Summary
<3–6 sentences, plain prose, no bullets, no headings inside>

## Action Items
- [ ] <actor>: <task> (<due if mentioned>)
- [ ] <actor>: <task>

If no action items are in the transcript, write:
## Action Items
_None identified._

Rules:
- Never invent facts. If something isn't said, don't add it.
- Use speaker names where present in the transcript; fall back to "the team" or "someone".
- Action items are the MINIMUM — only include items someone actually committed to.

Transcript:
<<<
{TRANSCRIPT}
>>>
```

- `{TRANSCRIPT}` is replaced with the plain-text body joined by speaker labels where diarized.
- Exact model-specific chat-template wrapping (Gemma uses `<start_of_turn>user` / `<start_of_turn>model`) is handled by `MLXLLM`'s tokenizer — we pass the template body as the user turn, no manual chat-template assembly.

### 5.2 Transcript rendering

`SummaryPrompt.render(transcript:)` — reuses the existing `MarkdownExporter` shape minus front-matter:

```
Jason: Welcome everyone. I want to start with the roadmap.
Amy: Before that — do we have a resolution on the Q3 pricing?
…
```

Line breaks between speaker turns. If `transcript.wordCount > contextBudgetWords` (see §6.2), truncate from the **start**, prepend a `[Earlier in the meeting…]` line, and keep the tail. Rationale: the end of a meeting has the summary and action items the speakers just restated — cheaper to keep than the beginning.

### 5.3 Parser

`SummaryParser.parse(_ raw: String) -> SummaryOutput`:

1. Split on `## Summary` and `## Action Items` headers. Be lenient: Gemma sometimes re-emits the fence. Find the FIRST `## Summary` and the NEXT `## Action Items`; everything after the second header is action items, everything between is summary.
2. Action item body: match lines starting with `- [ ]` or `- [x]`; ignore the rest. If the single body line is `_None identified._`, return an empty `actionItems` array.
3. Within each action item, parse optional `actor:` prefix and optional `(...)` due suffix into the `ActionItem` struct below. Failures stay as free-form `text`.

```swift
public struct ActionItem: Codable, Equatable, Sendable {
    public var text: String
    public var actor: String?   // "Jason"
    public var due: String?     // "Friday"
    public var done: Bool       // false on generation; user can check boxes
}
```

Malformed output from Gemma (no `## Summary` section, stray prose around fences) → emit a `SummaryOutput` with `summary = raw`, `actionItems = []`, and a flag `parseWarning = true` surfaced in a `ⓘ` tooltip in the UI so the user can still read something.

---

## 6. Context + throughput budget

### 6.1 Model-specific context windows

Pulled from each descriptor's `contextTokens` (filled by the manifest-refresh script). For v1 we assume Gemma 4 E2B/E4B/26B-A4B ship with at least **32k tokens** context. Verify against the model card at implementation time.

### 6.2 Budget

```swift
let budgetTokens = min(descriptor.contextTokens, 32_000) - promptOverhead(≈1200) - maxOutputTokens(1024)
```

Translate to words using a conservative 1.3 tokens/word for English — `budgetWords = budgetTokens / 1.3`. A 1-hour meeting is roughly 9k words, well within budget for all three tiers. Very long (4h+) transcripts get head-truncated with the `[Earlier in the meeting…]` prefix.

### 6.3 Max output tokens

Fixed at 1024. A 6-sentence summary + 10 action items comfortably fits.

---

## 7. UI — `SummaryCardView`

Rendered inside `TranscriptionDetailView`, just below the title block and above `SpeakerNameEditor`.

### 7.1 States

| State | Shown when |
|---|---|
| Empty + CTA | `summary_markdown IS NULL` AND the queue is NOT currently processing this ID |
| Progress | queue is processing this ID |
| Summary | `summary_markdown IS NOT NULL` |
| Empty + install prompt | Active summarizer not installed — renders `ModelRequirementView` from Model Manager |

### 7.2 Rendered summary card

```
┌──────────────────────────────────────────────────────────┐
│ Summary                     generated with Standard · ↻ ⋯│
│                                                          │
│ The team reviewed the Q3 roadmap. Amy raised pricing as  │
│ a blocker for the enterprise tier. Jason committed to    │
│ a rewrite of the tiering page by Friday. No decision on  │
│ headcount — revisit next week.                           │
│                                                          │
│ Action Items                                             │
│  ☐ Jason: rewrite tiering page (Friday)                  │
│  ☐ Amy: schedule follow-up on pricing                    │
│  ☑ Sam: file GDPR ticket                                 │
└──────────────────────────────────────────────────────────┘
```

- `↻` regenerates with the currently-active summarizer.
- `⋯` overflow: `Copy summary`, `Copy action items`, `Clear summary`.
- Checkboxes on action items toggle `done` on the item and persist via `RecordingStore.updateSummary`. Transcript is untouched.

### 7.3 Progress card

```
┌──────────────────────────────────────────────────────────┐
│ ⏳ Summarizing with Gemma 4 · Standard…            Cancel│
│    ─────────────────────────────────────                 │
│    Queued · #2 of 3                                      │
└──────────────────────────────────────────────────────────┘
```

The `#N of M` reflects `SummarizationQueue` length.

### 7.4 Copy-for-Prompt integration

When `HarcPreferences.includeSummaryInPrompt == true` and the recording has a summary, `ExportService.promptString(for:)` prepends:

```
## Summary
<summary_markdown verbatim>

## Action Items
<action_items_markdown verbatim>

## Transcript
<existing body>
```

The front-matter gains two keys: `summary_model: "gemma-4-e2b-it-4bit"` and `summarized_at: 2026-04-22T14:03:00Z`. Downstream LLMs can ignore or honor these.

---

## 8. Test plan

### 8.1 Unit tests (HarcSummarizeTests)

- `SummaryPrompt.render(transcript:)` snapshot tests against a short diarized transcript — verifies speaker labeling carries through and truncation kicks in at the word budget.
- `SummaryParser.parse` on:
  - happy path: well-formed Gemma output → extracts 3 action items
  - no action items ("_None identified._") → empty `actionItems`
  - stray prose after the fences → ignored
  - completely malformed (no headers) → `summary = raw`, `parseWarning = true`
  - action item with `actor:` + `(due)` → parsed into structured fields
  - action item without actor → `actor = nil`, full line in `text`

### 8.2 Store tests (HarcStoreTests)

- `RecordingStore.updateSummary` round-trip: set, fetch, clear, fetch.
- Migration `v6_summary` adds the four columns without dropping data.

### 8.3 Queue tests (HarcSummarizeTests)

- Enqueue 3 IDs → only one active at a time, others wait.
- Cancel mid-flight → `CancellationError` observed; queue advances to next.
- Dedupe on same-ID enqueue.

### 8.4 Integration (manual QA list — flagged in the plan doc, not a unit test)

- Kick off a 60-minute recording with Gemma 4 E2B installed; confirm summary appears ≤ 2 min after stop on an M3 Max, plausible text.
- Unplug the laptop; confirm auto-summarize is skipped when `autoSummarizeOnBatteryEnabled = false`.
- Uninstall the active summarizer while the queue is running → current job finishes with stale model in-memory; next job hits the `ModelRequirementView` install prompt.

---

## 9. Rollout

- v1 ships with auto-summarize **on by default**, but only fires when a summarizer is installed — so a fresh install is summary-less until the user hits the Install prompt once.
- Defer on-battery summarization off by default. The first time a user denies auto-summarize on battery, we don't re-ask.
- No remote export of summaries; they live in the existing on-device DB.

---

## 10. Open questions

- **Unload model after N minutes of idle?** Keeps RAM footprint low. I'd add it post-v1 after seeing real usage patterns — premature otherwise.
- **Expose a "quality / speed" dial distinct from model tier?** Could surface `maxOutputTokens` or `temperature`. No — this is a product-opinion feature; fewer knobs is better.
- **Should the summary be pinned to the transcript version?** If the user refines with beam search (separate spec), the summary becomes stale. Flag it: store the `source_word_count` at generation time; if the transcript's current word count differs by >5 %, show a subtle "summary is based on an older transcript" nudge above the card.
