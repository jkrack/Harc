# Local Summarization (Gemma 4 via MLX) Design Doc

**Feature:** After a recording finishes, generate a structured summary + action items from the transcript using a locally-installed Gemma 4 model via MLX. Stored on the recording, shown in the Library detail pane, included in the Copy-for-Prompt blob. Opt-in, never blocks the recording pipeline, always deferrable.
**Date:** 2026-04-22 (revised 2026-04-23: phasing, current-codebase fixes; revised again 2026-04-23: single-stack MLX via `mlx-swift-lm` 3.x)
**Status:** draft — ready for implementation
**Depends on:** `2026-04-22-model-manager-design.md` (Gemma 4 weights + install UX). Phase 1 of the model manager is complete as of 2026-04-23: `ModelManager` (actor) + `ModelManagerStore` (`@MainActor` `@Published` bridge) are constructed in `AppDelegate` and injected via `.environmentObject`. There is no `ModelManager.shared` singleton; this spec threads the existing instances.

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
  - `SummaryParser` — splits Gemma's output into structured summary + action items.
  - `SummaryOutput` — plain data struct with `summary: String` (markdown), `actionItems: [ActionItem]`, `model: String` (descriptor id), `generatedAt: Date`, `elapsedMs: Int`, `sourceWordCount: Int` (transcript word count at generation time — drives the staleness nudge in §7.2).
  - `SummarizationQueue` actor + `SummarizationQueueStore` (`@MainActor` `@Published` bridge mirroring `ModelManagerStore` so SwiftUI views render per-recording queue state without polling).
- Five new columns on `recordings`: `summary_markdown TEXT NULL`, `action_items_markdown TEXT NULL`, `summary_model_id TEXT NULL`, `summary_generated_at INTEGER NULL` (Unix ms), `summary_source_word_count INTEGER NULL`. One `DatabaseMigrator` migration `v7_summary` (the current head is `v6_speaker_embeddings`).
- `RecordingStore.updateSummary(id:, output:)` / `.clearSummary(id:)` wires.
- `SummarizationQueue` actor that consumes a queue of recording IDs (see §4.2). Only one summary runs at a time — RAM usage of a loaded LLM is non-trivial.
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

**Single-stack MLX.** `MLXLLM` and `MLXLMCommon` moved out of `mlx-swift-examples` into `mlx-swift-lm` in the 3.x rewrite (early 2025). The tokenizer is now a protocol, adapted via the `MLXHuggingFace` macro that ships inside `mlx-swift-lm`. `MLXEmbedders` — needed later for semantic search — also lives in the same `mlx-swift-lm` package, so adopting it costs zero additional packages. No Core ML, no dual stack.

Add to `Package.swift`:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),
.package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
.package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
```

Targets:

```swift
.target(
    name: "HarcSummarize",
    dependencies: [
        "HarcCore",
        "HarcStore",
        "HarcModels",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ]
),
.testTarget(
    name: "HarcSummarizeTests",
    dependencies: ["HarcSummarize", "HarcCore", "HarcStore"]
),
```

`HarcUI` gains a dep on `HarcSummarize` (needed for the card) and a new env-object `SummarizerService`. `MLX` from `mlx-swift` is a transitive dep — add it explicitly only if we end up using `MLXArray` directly in our own code (we shouldn't for this feature).

**Version pin rationale.** `mlx-swift-lm` `3.31.3` is the April 2026 release that registers Gemma 4 in `LLMTypeRegistry` (both `"gemma4"` and `"gemma4_text"` model types) and provides the `loadContainer(from: URL, using: TokenizerLoader)` local-directory API this spec relies on. `swift-huggingface` + `swift-transformers` are first-party HuggingFace packages, pulled in as the adapter for the `#huggingFaceTokenizerLoader()` macro; they're stable at 1.x / 0.9.x respectively.

---

## 4. Pipeline

### 4.1 Trigger

Concretely, at the tail of `AppDelegate.stopRecording(autoStopReason:)` after the existing `runAutoPaste(for:shiftHeld:)` call. `summarizationQueue` is a new AppDelegate-owned instance, mirroring `modelManager` / `modelStore`:

```swift
if prefs.autoSummarizeEnabled,
   shouldSummarizeGivenPower(),                           // honors autoSummarizeOnBatteryEnabled
   modelStore.state(of: prefs.activeSummarizerID).isInstalled,
   let id = rec.id {
    await summarizationQueue.enqueue(recordingID: id)
}
```

`modelStore` is the `@MainActor` `ModelManagerStore` already injected into the SwiftUI environment — we read it synchronously rather than awaiting the underlying actor. `shouldSummarizeGivenPower()` reads `IOPSCopyPowerSourcesInfo` — if on battery AND `autoSummarizeOnBatteryEnabled == false`, skip. The summary gets enqueued next time the user opens the detail pane of an un-summarized recording, or they can click Generate manually.

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
    private var container: ModelContainer?   // from MLXLMCommon

    public func summarize(
        transcript: PromptTranscript,
        modelID: String,
        budgetWords: Int
    ) async throws -> SummaryParseResult

    /// Release the resident model so MLX can reclaim GPU/ANE memory.
    /// Implemented by setting `container = nil` — `mlx-swift-lm` 3.x has
    /// no explicit `unload()` method; nil-ing the container is the
    /// documented way to drop weights.
    public func unload()
}
```

- First call with a given `modelID` loads the model from `~/Library/Application Support/Harc/Models/<id>/` via `LLMModelFactory.shared.loadContainer(from:using:)`. Subsequent calls with the same id reuse the container.
- `SummarizerService.summarize` builds the user-turn body via `SummaryPrompt.build` (Stage 1, already shipped), then wraps it in a `UserInput` with the system message, calls `container.prepare(input:)` + `container.generate(input:parameters:)`, aggregates `Generation.chunk(String)` payloads into one string, and passes the result to `SummaryParser.parse` (Stage 1, already shipped). Return type is `SummaryParseResult`; the caller in Stage 3 (the queue) wraps with metadata (`model`, `generatedAt`, `elapsedMs`, `sourceWordCount`) into a full `SummaryOutput`.
- Cancellation is structured-concurrency native: the queue's `Task` holds the `for await` loop; calling `task.cancel()` terminates the `AsyncStream<Generation>` mid-generation and `summarize` throws `CancellationError`.

### 4.4 Memory pressure

- On `NSWorkspace.didActivateApplicationNotification` for a heavyweight app (Chrome, Final Cut), or on explicit memory pressure from `DispatchSource.makeMemoryPressureSource(...)`, call `SummarizerService.unload()` to free the resident model. That call sets `container = nil`; MLX's reference-counting on GPU memory then reclaims the weights. Next summary pays the load cost again.
- The LLM is idle between summaries but still resident. A future `unloadAfterIdleSeconds` setting could trim this; v1 keeps it loaded for the app lifetime once first used.
- `mlx-swift-lm` also exposes `WiredMemoryPolicy` / `WiredMemoryTicket` for coordinating wired-memory budget across concurrent inferences. Stage 2 doesn't need this (we only have one tenant — summarization). When semantic search lands as a second tenant, add a shared ticket pool so the two don't thrash.

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
- Exact model-specific chat-template wrapping (Gemma uses `<start_of_turn>user` / `<start_of_turn>model`) is handled by `swift-transformers`' `Tokenizer` reading the model's `chat_template.jinja` — we pass the template body as the user turn, no manual chat-template assembly.
- **Gemma 4 EOS gotcha.** Gemma 4 uses `<turn|>` as an extra EOS token (different from Gemma 3's `<end_of_turn>`). `LLMModelFactory.shared.loadContainer(from:using:)` reads EOS tokens from the model directory's `config.json` + `generation_config.json`, so this is handled automatically as long as those files made it through the download. The pre-Stage-2 spike (§11) verifies they did.

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
- **Staleness nudge.** If the current transcript word count differs from the persisted `summary_source_word_count` by more than 5 %, render a one-line banner above the summary text: `Summary is based on an older transcript. Regenerate?` with a click-target on `Regenerate`. Comparison happens in the view, not the DB; no migration cost beyond the column itself.

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
- Migration `v7_summary` adds the five columns to a seeded v6 DB without dropping data.

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

Resolved during 2026-04-23 spec revision — kept here for the trail:

- **Unload model after N minutes of idle?** Deferred to v2. v1 keeps the model resident for the app lifetime once first loaded; explicit pressure-driven unload (§4.4) is enough.
- **Expose a "quality / speed" dial distinct from model tier?** No. The tier picker is the only knob; `maxOutputTokens` / `temperature` are not user-facing.
- **Pin the summary to the transcript version?** Yes — included in v1. Store `source_word_count` on the row (driven by the new column in §2). When the current transcript word count differs from `source_word_count` by >5 %, `SummaryCardView` shows a subtle "summary is based on an older transcript" nudge above the card with a one-click regenerate (see §7.2).

---

## 11. Implementation phasing

The work splits into four stages. Each stage is a coherent commit that builds and ships green tests; later stages depend on earlier ones but can be reviewed independently.

### Stage 1 — Pure scaffolding (no MLX, no DB)

**Adds:**
- New SwiftPM target `HarcSummarize` (depends on `HarcCore` only at this stage).
- `SummaryOutput`, `ActionItem` value types (`Codable`, `Equatable`, `Sendable`).
- `SummaryPrompt` — the §5.1 template + `render(transcript:)` from §5.2 (head-truncation included).
- `SummaryParser.parse(_:)` covering all branches in §5.3 (well-formed, no items, malformed, actor + due parsing).

**Tests** (`HarcSummarizeTests`): full §8.1 unit tests — prompt snapshot, parser branches.

**No app integration in this stage.** Validates the prompt + parser shape before introducing the MLX dependency.

### Stage 2 — MLX wiring + SummarizerService

**Adds:**
- `mlx-swift-lm` (3.31.3+), `swift-huggingface` (0.9+), `swift-transformers` (1.3+) packages (verified pins per §3).
- `HarcSummarize` gains `MLXLLM` / `MLXLMCommon` / `MLXHuggingFace` / `HuggingFace` / `Tokenizers` deps.
- `SummarizerService` actor (§4.3): `summarize(transcript:modelID:budgetWords:)`, `unload()`. Loads from `~/Library/Application Support/Harc/Models/<id>/` via `LLMModelFactory.shared.loadContainer(from:using:)`, resolved through the AppDelegate-injected `ModelManager`. Returns `SummaryParseResult`; metadata wrapping happens in Stage 3.
- Memory pressure unload hook (§4.4) — sets `container = nil` rather than calling a non-existent `.unload()`.
- Manual integration test (XCTest, marked `XCTSkip` unless `HARC_INTEGRATION_TESTS=1` env var is set + Gemma 4 E2B is installed) that runs one summary against a known fixture transcript and asserts non-empty `summary` + parses cleanly.

**No queue, no UI, no DB writes** — Service is callable but nothing in the app calls it yet.

### Stage 3 — Persistence, queue, trigger

**Adds:**
- DB migration `v7_summary` adding the five columns from §2.
- `RecordingStore.updateSummary(id:output:)` / `clearSummary(id:)`.
- `SummarizationQueue` actor (§4.2) + `SummarizationQueueStore` (`@MainActor` `@Published` bridge).
- `BackgroundWorkCoordinator` actor (defined in spec for semantic-search interop; introduced here, not used externally yet).
- `HarcPreferences.autoSummarizeEnabled` (default `true`), `autoSummarizeOnBatteryEnabled` (default `false`), `includeSummaryInPrompt` (default `true`).
- AppDelegate wires: constructs queue + service, injects `summarizationQueueStore` into the SwiftUI environment, fires the §4.1 trigger from `stopRecording`.
- One-time on-launch enqueue of un-summarized recordings (so a fresh install with previously-recorded meetings catches up).

**Tests** (`HarcStoreTests`, `HarcSummarizeTests`): migration, `updateSummary` round-trip, queue serialization (3 enqueued → 1 active at a time), cancellation, dedupe-on-insert.

### Stage 4 — UI: SummaryCardView + Copy-for-Prompt

**Adds:**
- `SummaryCardView` in `HarcUI` rendering all four states from §7.1 (empty/CTA, progress, summary, install-required via `ModelRequirementView`).
- Mounted in `TranscriptionDetailView` between the title block and `SpeakerNameEditor`.
- Action-item checkboxes that persist via `updateSummary`.
- Staleness nudge from §7.2.
- `ExportService.promptString(for:)` extension for the §7.4 `## Summary` / `## Action Items` block.
- New `PromptFrontMatter` keys: `summary_model`, `summarized_at`.

**Tests** (`HarcUITests`, `HarcExportTests`): card state-machine snapshot tests, `promptString` snapshot with + without summary, front-matter contains the new keys when present.

### Sequencing & blast radius

- Stages 1–3 are reviewable / mergeable without user-visible behavior change. After Stage 3 the trigger fires and writes to the DB columns, but no view in the existing app reads them, so the user sees nothing different.
- Stage 4 is the user-visible flip. Easy to revert independently if anything's wrong with the card UX.
- A pre-Stage-2 spike — verify the catalog's Gemma 4 E2B descriptor downloads end-to-end on a real machine (not a unit test), confirm `generation_config.json` is in the file list (carries the `<turn|>` EOS), and confirm `LLMModelFactory.shared.loadContainer(from:using:)` accepts the resulting directory — is **required** before Stage 2 so we're not debugging "why won't this load" with two unknowns at once. Treat as a half-day exploration, not a stage. The 2026-04-23 manifest HEAD-check spike already confirmed all 8 catalog file URLs return 200 with sizes within ±0.25 % of expected — what remains is the real download + the MLX load test.

---

## 12. Stage 3 refresh (2026-04-24)

Supersedes the Stage 3 bullets in §11 where it contradicts them. Written after Stages 1–2 merged to `main` (PRs #1, #2) and the codebase was audited against §11's original wording. Keeps the stage's user-visible surface area identical — all changes are internal shape / dep-direction.

### 12.1 Tight reconciliations to earlier sections

- **§4.3 signature.** Stage 2 shipped `SummarizerService.summarize(transcript:modelID:modelDirectory:budgetWords:)` — directory resolution lives outside the actor. The `SummarizationQueue`'s `perform` closure (§12.4) calls `ModelManager.requireInstalled(...)` and passes the directory in.
- **§4.4 heavyweight-app unload.** `NSWorkspace.didActivateApplicationNotification`-driven unload is deferred past v1. Pressure-driven unload (the `DispatchSource` set up in Stage 2) covers the memory case adequately; one mechanism is enough until there's evidence otherwise.
- **§2 `updateSummary` signature.** Spelled as `updateSummary(id:output:)` taking `SummaryOutput`. `SummaryOutput` lives in `HarcSummarize`; `HarcStore` currently depends only on `HarcCore` + `GRDB`. Flipping that dep direction is the wrong way. Replaced with a primitives-based signature (§12.3) matching the `updateSpeakerNames` / `updateTags` / `updateSuggestedTitle` precedent.
- **§3 `HarcSummarize` deps.** `HarcStore` and `HarcModels` are NOT added as deps in Stage 3. The queue is closure-driven (§12.4), and the `SessionTranscript → PromptTranscript` adapter takes HarcCore primitives rather than `HarcClient.SessionTranscript` directly (§12.4). Keeps HarcSummarize at its current dep footprint: HarcCore + the MLX/tokenizer packages.

### 12.2 DB migration `v7_summary`

One `alter(table:)` adding exactly the five columns from §2:

```swift
migrator.registerMigration("v7_summary") { db in
    try db.alter(table: "recordings") { t in
        t.add(column: "summary_markdown", .text)
        t.add(column: "action_items_markdown", .text)
        t.add(column: "summary_model_id", .text)
        t.add(column: "summary_generated_at", .integer)  // Unix ms
        t.add(column: "summary_source_word_count", .integer)
    }
}
```

`Recording` struct gains five matching optional fields + `Columns` entries + `CodingKeys`. `summary_generated_at` stored as Int64 milliseconds since epoch for SQLite portability. No FTS changes — summary isn't searchable in v1.

**Action-item persistence is markdown-authoritative.** `action_items_markdown` holds the `- [ ]`/`- [x]` block verbatim. The UI re-parses on read via the existing `SummaryParser`; on `done` toggle it re-serializes through `ActionItemsMarkdown.render` (§12.4) and writes the column back. Round-trip is lossless for `text`, `actor`, `due`, `done`. `SummaryOutput.parseWarning` does not round-trip — it's generation-time-only and is lost once the row is persisted (acceptable: if parsing was clean enough to render a summary at all, the warning was already cosmetic).

### 12.3 `RecordingStore` additions

```swift
public func updateSummary(
    id: Int64,
    markdown: String,
    actionItemsMarkdown: String,
    modelID: String,
    generatedAt: Date,
    sourceWordCount: Int
) async throws

public func clearSummary(id: Int64) async throws

/// Rows with a transcript but no summary yet. Ordered startedAt DESC.
/// Bounded — on-launch catch-up shouldn't seed hundreds of jobs.
public func unsummarizedRecordings(limit: Int = 20) async throws -> [Recording]
```

`unsummarizedRecordings` filter: `deleted_at IS NULL AND summary_markdown IS NULL`. The `limit` default of 20 keeps first-run backlog bounded on a library that predates the summarization feature; beyond that the user regenerates older rows manually from the Stage 4 card.

`updateSummary` + `clearSummary` update `updated_at` on write so the existing FTS5 sync / `observeAll` stream re-emit. Both throw `StoreError.notFound` if the id is missing — consistent with `setPinned` / `rename`.

### 12.4 `HarcSummarize` new files

No new external package deps. Five new files, all in `Sources/HarcSummarize/`:

- **`PromptTranscriptAdapter.swift`** — pure static function, HarcCore types in, `PromptTranscript` out:
  ```swift
  public enum PromptTranscriptAdapter {
      public static func make(
          joinedText: String,
          words: [Word],
          speakers: [SpeakerSegment],
          speakerNameOverrides: [Int: String]
      ) -> PromptTranscript
  }
  ```
  Algorithm mirrors `HarcClient.TranscriptPlainTextRenderer`: assign each word to a speaker via midpoint containment → collapse into contiguous same-speaker runs → one `Utterance` per run with label `speakerNameOverrides[i] ?? "Speaker \(i+1)"`. If speakers are empty or words are empty, returns one `Utterance(speaker: nil, text: joinedText)`. The call site (§12.5) unwraps `SessionTranscript` into primitives.

- **`ActionItemsMarkdown.swift`** — inverse of `SummaryParser`:
  ```swift
  public enum ActionItemsMarkdown {
      public static func render(_ items: [ActionItem]) -> String
  }
  ```
  Empty → `"_None identified._"`. Otherwise one line per item:
  - `done == true`  → `- [x] …`
  - `done == false` → `- [ ] …`

  The body shape: `<actor>: <text> (<due>)` when actor + due present, with `:`, `(`, `)` dropped progressively as fields are absent. Round-trip with `SummaryParser.parse` is covered by tests.

- **`BackgroundWorkCoordinator.swift`** — matches the semantic-search spec §10 signature exactly:
  ```swift
  public actor BackgroundWorkCoordinator {
      public init()
      public func performOne<T>(_ op: () async throws -> T) async rethrows -> T
  }
  ```
  One-slot serial mutex. Internally a `waiters: [CheckedContinuation<Void, Never>]` + a `busy: Bool` flag, or equivalent `AsyncSemaphore` pattern. In Stage 3 the only producer is summarization, so this is a pass-through; defining it now prevents a queue refactor when semantic search lands.

- **`SummarizationQueue.swift`** — actor with this surface:
  ```swift
  public actor SummarizationQueue {
      public typealias Perform = @Sendable (Int64) async throws -> Void

      public init(
          coordinator: BackgroundWorkCoordinator,
          perform: @escaping Perform
      )

      public func enqueue(_ id: Int64)
      public func cancel(_ id: Int64)
      public func cancelAll()

      public private(set) var pending: [Int64]
      public private(set) var current: Int64?

      public nonisolated func events() -> AsyncStream<Event>
  }

  public enum Event: Sendable {
      case enqueued(Int64)
      case started(Int64)
      case finished(Int64, Result<Void, Error>)
      case queueDrained
  }
  ```
  Behaviour:
  - `enqueue(id)` appends to `pending` unless `id == current || pending.contains(id)` (dedupe). Emits `.enqueued`. Starts the worker task if none is running.
  - Worker loop: pop head → set `current` → emit `.started` → `coordinator.performOne { try await perform(id) }` → emit `.finished(id, .success(()))` or `.finished(id, .failure(error))` → clear `current`. On empty pending: emit `.queueDrained`, exit loop.
  - `cancel(id)`: if `id` is in `pending`, remove it. If `id == current`, call `task.cancel()` on the in-flight `Task`. Structured concurrency propagates through `perform`; `SummarizerService.summarize`'s `Generation` stream tears down and throws `CancellationError`. The `.finished` event carries `.failure(CancellationError())`, which the UI distinguishes from `SummarizerError` cases.
  - `cancelAll`: clears pending, cancels the in-flight task.
  - No disk persistence. App quit drops everything; the on-launch catch-up in §12.5 re-seeds from un-summarized rows.

- **`SummarizationQueueStore.swift`** — `@MainActor ObservableObject` mirroring `ModelManagerStore`:
  ```swift
  @MainActor
  public final class SummarizationQueueStore: ObservableObject {
      @Published public private(set) var pending: [Int64] = []
      @Published public private(set) var current: Int64? = nil

      public init(queue: SummarizationQueue)

      public func isQueued(_ id: Int64) -> Bool   // pending OR current
      public func position(_ id: Int64) -> Int?   // 1-based for "#2 of 3"
      public func totalInFlight: Int              // pending.count + (current != nil ? 1 : 0)
  }
  ```
  Subscribes to `queue.events()` at init on a detached `Task`, forwards state to `@Published` on `MainActor`.

### 12.5 `HarcPreferences` additions

Three new `@Published var` on the existing singleton, with matching UserDefaults keys:

```swift
@Published public var autoSummarizeEnabled: Bool           // default true
@Published public var autoSummarizeOnBatteryEnabled: Bool  // default false
@Published public var includeSummaryInPrompt: Bool         // default true
```

`includeSummaryInPrompt` is Stage 4's knob; storing it now keeps the pref surface stable across both merges. No Settings UI in Stage 3.

### 12.6 `AppDelegate` wiring

Six edits:

1. **Graph construction** after `bootstrapStore` sets `self.store`:
   ```swift
   let coordinator = BackgroundWorkCoordinator()
   let service = SummarizerService(loader: SummarizerService.defaultLoader)
   self.memoryObservation = service.startObservingMemoryPressure()  // retain
   let queue = SummarizationQueue(coordinator: coordinator, perform: { [weak self] id in
       try await self?.performSummarization(id: id)
   })
   self.summarizerService = service
   self.summarizationQueue = queue
   self.summarizationQueueStore = SummarizationQueueStore(queue: queue)
   ```
   `memoryObservation` is a new `AppDelegate` property holding `SummarizerService.MemoryPressureObservation` for the app's lifetime (hand-off note 2 from Stage 2).

2. **`performSummarization(id:)`** — private `@MainActor` helper, the closure the queue calls. Pseudocode:
   ```swift
   guard let store = self.store, let service = self.summarizerService else { return }
   guard let rec = try await store.fetch(id: id),
         let jsonPath = rec.jsonPath else { return }
   let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
   let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
   let sessionTranscript = try decoder.decode(SessionTranscript.self, from: data)

   let promptTranscript = PromptTranscriptAdapter.make(
       joinedText: sessionTranscript.joinedText,
       words: sessionTranscript.words,
       speakers: sessionTranscript.speakers,
       speakerNameOverrides: rec.speakerNames
   )

   let modelID = prefs.activeSummarizerID
   guard let descriptor = await modelManager.descriptor(for: modelID) else { return }
   let directory = try await modelManager.requireInstalled(modelID)
   let budgetWords = SummaryPrompt.budgetWords(contextTokens: descriptor.contextTokens)

   let result = try await service.summarize(
       transcript: promptTranscript,
       modelID: modelID,
       modelDirectory: directory,
       budgetWords: budgetWords
   )

   try await store.updateSummary(
       id: id,
       markdown: result.summary,
       actionItemsMarkdown: ActionItemsMarkdown.render(result.actionItems),
       modelID: modelID,
       generatedAt: Date(),
       sourceWordCount: wordCount(in: sessionTranscript.joinedText)
   )
   ```
   `rec.jsonPath == nil` (rare — a recording ingested without a JSON sidecar) is a no-op early return: we don't fall back to `rec.transcriptText` alone because losing the speaker segments would silently degrade the summary. The queue emits `.finished(.success(()))` and advances; the user can re-trigger manually from the Stage 4 card once a sidecar is present.

3. **Trigger in `stopRecording`** — capture the upsert return value, enqueue after the existing `runAutoPaste` call:
   ```swift
   let saved: Recording? = try? await self.store?.upsert(rec)  // replaces the _ = try? … line
   // … existing title/tags/reID code unchanged …
   runAutoPaste(for: rec, shiftHeld: …)
   if prefs.autoSummarizeEnabled,
      shouldSummarizeGivenPower(),
      modelStore.state(of: prefs.activeSummarizerID).isInstalled,
      let id = saved?.id,
      let queue = self.summarizationQueue {
       await queue.enqueue(id)
   }
   ```

4. **`shouldSummarizeGivenPower()`** — private `@MainActor` helper:
   ```swift
   import IOKit.ps
   private func shouldSummarizeGivenPower() -> Bool {
       if prefs.autoSummarizeOnBatteryEnabled { return true }
       guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
           return true   // IOKit probe failed → don't silently skip the user's opt-in
       }
       let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
       // Skip only when we can positively confirm battery-only power. Anything
       // else (AC, unknown, desktop with no battery) → summarize.
       return type != kIOPSBatteryPowerValue
   }
   ```
   The user explicitly opted into auto-summarize by leaving `autoSummarizeEnabled = true`; we only skip when we can affirmatively confirm battery-only power. Desktops without a battery (Mac Pro, Studio, Mini) report an AC/unknown type and summarize normally.

5. **On-launch catch-up** — at the tail of `bootstrapStore`, after Stage 3 graph is built:
   ```swift
   if prefs.autoSummarizeEnabled,
      shouldSummarizeGivenPower(),
      modelStore.state(of: prefs.activeSummarizerID).isInstalled {
       let rows = (try? await store.unsummarizedRecordings(limit: 20)) ?? []
       for rec in rows { if let id = rec.id { await queue.enqueue(id) } }
   }
   ```

6. **Environment injection** — `refreshPopoverRoot` gains `.environmentObject(summarizationQueueStore)` alongside the existing `.environmentObject(modelStore)`. Stage 4 views consume it; Stage 3 just makes it available.

### 12.7 Test plan

- `HarcStoreTests`:
  - `v7_summary` migrates a seeded v6 DB without dropping any rows or columns; new columns are nullable and default to nil.
  - `updateSummary` round-trip: write → fetch by id → all five columns match; `updated_at` advances.
  - `clearSummary` nulls all five columns; `updated_at` advances; `notFound` throws on unknown id.
  - `unsummarizedRecordings`: excludes soft-deleted, excludes already-summarized, respects `limit`, orders by `started_at DESC`.
- `HarcSummarizeTests`:
  - `PromptTranscriptAdapter` — undiarized (one utterance with nil speaker), two-speaker diarized (correct runs + default `Speaker N` labels), speaker-name override applied (`speakerNames[0] = "Amy"` → utterance labeled `Amy`), empty transcript returns empty `utterances`.
  - `ActionItemsMarkdown.render` — empty → `"_None identified._"`; done=true → `- [x] …`; actor + due + text round-trips cleanly through `SummaryParser.parse`.
  - `SummarizationQueue` — three enqueues execute sequentially (overlap counter stays ≤ 1), dedupe on same-id enqueue, cancel queued id skips invocation, cancel current id surfaces `CancellationError` in the `.finished` event and advances the queue, `events()` stream ordering (`.enqueued → .started → .finished → .queueDrained`).
  - `BackgroundWorkCoordinator` — two concurrent `performOne` calls serialize (overlap counter ≤ 1), rethrows propagate, cancellation of the outer task propagates.
- Manual QA (Stage 4 surfaces it visibly, Stage 3 just verifies the DB write):
  - Record a short meeting with Gemma 4 E2B installed → SQL-inspect `recordings` → summary columns populated within a minute or two.
  - Unplug → record → verify auto-summarize is skipped when `autoSummarizeOnBatteryEnabled = false`.
  - Toggle `autoSummarizeEnabled = false` in UserDefaults → record → verify no enqueue.

### 12.8 Implementation phasing (subagent-driven tasks)

Seven independently-reviewable tasks, roughly bottom-up:

1. **Migration + Recording columns + store round-trip.** `v7_summary`, extend `Recording` struct (fields + Columns + CodingKeys), `updateSummary` / `clearSummary`. Tests: migration from v6, round-trip, `notFound`.
2. **`unsummarizedRecordings` query** + filter/order/limit tests.
3. **`PromptTranscriptAdapter`** + unit tests across four scenarios.
4. **`ActionItemsMarkdown.render`** + round-trip tests through `SummaryParser`.
5. **`BackgroundWorkCoordinator`** + serialization + cancellation tests.
6. **`SummarizationQueue` + `SummarizationQueueStore`** + the four queue behaviours + event stream ordering.
7. **`HarcPreferences` additions + `AppDelegate` wiring** (graph, trigger, on-launch catch-up, `shouldSummarizeGivenPower`, memory-pressure observation, environment injection). The only task without pure unit tests; manual QA covers it.

Tasks 1–6 are each mechanical TDD (Haiku implementer + Sonnet spec-compliance review + `superpowers:code-reviewer` for tasks with real logic). Task 7 integrates them; lighter review since it's plumbing but still code-reviewer-gated because it touches the user-facing app.

### 12.9 What ships visibly after Stage 3 merges

**Nothing user-visible.** The trigger fires, the queue runs, the DB row gets five new populated columns. No view in the existing app reads them. The sole observable change: a freshly-recorded meeting, a minute or two after stop, quietly has `summary_markdown` populated in the DB. Stage 4 is the UI flip — shipping it independently keeps the revert surface small.
