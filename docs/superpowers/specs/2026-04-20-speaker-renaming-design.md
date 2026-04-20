# Speaker Renaming + Persistence Design Doc

**Feature:** Let the user override the diarizer's default `Speaker 1`, `Speaker 2`, … labels with real names (`Jason`, `Amy`, …). Names persist per recording, flow through every export surface (Markdown, DOCX, clipboard prompt blob, `participants:` front-matter), and are edited inline from the Library detail pane.
**Date:** 2026-04-20
**Status:** draft — ready for implementation

---

## 1. Problem & user story

FluidAudio's diarizer emits integer speaker IDs (0, 1, 2, …). Harc renders them as `Speaker 1`, `Speaker 2`, … at export time — the labels exist only in the `MarkdownExporter` and `DocxExporter` output strings, never on disk or in the DB.

For the dominant paste-into-LLM flow, those labels are weak context. `"Speaker 1: What's the timeline?"` gives the LLM no way to attribute a claim to a person. `"Jason: What's the timeline?"` does — and lets the LLM say "Jason asked about the timeline" instead of "one of the speakers asked about the timeline." Everything downstream (summary quality, question-answering, action-item assignment) improves when the labels are names.

**User story.** "I stop a meeting recording. In the Library detail pane I see a Speakers section listing `Speaker 1`, `Speaker 2`. I type `Jason` and `Amy` into the fields. I hit Copy for Prompt and paste into Claude — the transcript reads `Jason: … / Amy: …` and the YAML front-matter carries `participants: Jason, Amy`."

**User story (partial rename).** "I only knew Jason's name, not Amy's. I type `Jason` into Speaker 1's field and leave Speaker 2 blank. Exports read `Jason: … / Speaker 2: …` and the front-matter's `participants:` line reads `Jason, Speaker 2` — the missing name falls back gracefully."

**User story (persistence).** "I rename speakers today, close the app, reopen it next week. The names are still there — they're attached to the recording, not to the app's session state."

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A new `speaker_names TEXT NULL` column on the existing `recordings` table, JSON-encoded `[String: String]` dict mapping a stringified speaker index to the override name. Added via `DatabaseMigrator` migration `v5_speaker_names`.
- `Recording.speakerNames: [Int: String]` field (default `[:]`) with Codable round-trip through the column.
- `RecordingStore.updateSpeakerNames(id:names:) async throws` — writes through to the DB.
- `ExportInput.speakerNames: [Int: String]` (default `[:]`), threaded by `ExportInputBuilder.build(from:)`.
- A new internal helper `SpeakerLabel.displayLabel(for:names:)` in `HarcExport` consumed by `MarkdownExporter`, `DocxExporter`, and `PromptFrontMatter`.
- `PromptFrontMatter` gains a conditional `participants:` line between `tags:` and `speakers:`, emitted when the recording has ≥2 distinct speakers AND at least one override.
- A `SpeakerNameEditor` SwiftUI view inserted into `TranscriptionDetailView`, showing one row per distinct speaker present in the recording, with inline-editable text fields that commit on Enter or focus-loss.
- Unit tests for the label helper, the updated exporters, the front-matter renderer, and the store round-trip.

**Out of scope / non-goals (v1):**

- **Auto-suggest speaker names** (from entities in the transcript — `"I spoke with Jason about…"`). Deferred explicitly; the original brief planned it as coming from a Tier 2 feature.
- **Voiceprint-based global aliases** that recognise "the same voice across recordings" and apply a single name to all occurrences. Speaker IDs are per-recording; this spec keeps that.
- **Editing from the Transcript Editor window** (`TranscriptEditorView`). The editor stays as a text/word-level editor in v1; speaker names live in the detail pane only.
- **Writing override names back to the on-disk `.json` sibling.** The `.json` stays as the diarizer's objective output; overrides are a user-layer concern that lives only in the DB. Portability of the `.json` across tools isn't compromised.
- **Anonymize-on-export toggle** (force `Speaker N` back in exports despite stored names). Trivial to add later if users want it.
- **Large-N speaker UX** (virtualised list, bulk rename). The realistic upper bound is 3–5 speakers per meeting; a simple stacked list of TextFields is enough.
- **IPC protocol changes.** Speaker renaming is purely client-side; the daemon never sees override names.
- **Migrating or filling names during the post-stop recording pipeline.** Overrides are a manual action; they stay empty until the user types.

---

## 3. Data shape

### 3.1 DB column

New column on `recordings`:

```sql
ALTER TABLE recordings ADD COLUMN speaker_names TEXT
```

`NULL` means "no overrides." When any override exists, the column holds a JSON-encoded `[String: String]` map where keys are the stringified speaker index:

```json
{"0": "Jason", "1": "Amy"}
```

Empty dict is serialized as `NULL`, not as `{}`, matching the existing `tags` pattern. Partial coverage is legal: `{"1": "Amy"}` with no entry for speaker 0 is valid and renders as `Speaker 1, Amy` via the label helper's fallback.

### 3.2 Swift shape

```swift
// Recording.swift (HarcStore)
public var speakerNames: [Int: String] = [:]
```

Rationale:

- **Dict, not array.** Sparse by construction — the user may rename Speaker 2 without touching Speaker 1. An array `[String?]` would need either a placeholder at index 0 or explicit length management. A dict also tolerates a diarizer re-run that introduces a new speaker index without requiring array growth.
- **`Int: String`, not `String: String`.** The natural in-memory key is an integer index (matches `SpeakerSegment.speaker` on the wire). JSON forces string keys — decode converts, encode stringifies. Invalid keys (non-integer strings) are silently dropped during decode.
- **Default `[:]`, not `nil`.** Everywhere `speakerNames` is consumed, the empty-dict case has a well-defined meaning (no overrides → all labels fall back). An optional would force unwrapping at every site for no behavioural gain.

### 3.3 Empty-string treatment

An entry with an empty-trimmed string (e.g. `{"0": ""}`) is semantically "no override." The label helper treats it the same as a missing key. The editor UI treats field blur with trimmed-empty content as "clear this override," which calls `updateSpeakerNames` with that key removed from the dict rather than stored as empty.

---

## 4. Rendering

### 4.1 `SpeakerLabel` helper (new, in HarcExport)

```swift
/// Single source of truth for the user-visible speaker label. Used by
/// MarkdownExporter, DocxExporter, and PromptFrontMatter so the fallback
/// ("Speaker N") and the override lookup never drift across renderers.
public enum SpeakerLabel {
    /// Returns the override name for `speaker` if present and non-empty,
    /// otherwise `"Speaker \(speaker + 1)"`. Returns `nil` when `speaker`
    /// is `nil` (un-diarized segment — callers omit the prefix entirely).
    public static func displayLabel(for speaker: Int?, names: [Int: String]) -> String? {
        guard let id = speaker else { return nil }
        if let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Speaker \(id + 1)"
    }
}
```

### 4.2 `MarkdownExporter`

Currently emits:

```swift
if let speaker = segment.speaker {
    let label = "Speaker \(speaker + 1)"
    out += "\(label): \(cleaned)\n"
}
```

Becomes:

```swift
if let label = SpeakerLabel.displayLabel(for: segment.speaker, names: input.speakerNames) {
    out += "\(label): \(cleaned)\n"
} else {
    out += "\(cleaned)\n\n"
}
```

The `speaker: nil` branch — plain paragraphs, no prefix — is preserved via `displayLabel` returning `nil`.

### 4.3 `DocxExporter`

Same swap at the one `Speaker \(speaker + 1)` call site. The `NSAttributedString` that includes the label becomes `NSAttributedString(string: "\(label): ", attributes: labelAttrs)` where `label` comes from `SpeakerLabel.displayLabel`.

### 4.4 `PromptFrontMatter.render(_:timeZone:)`

Adds one conditional field between the existing `tags:` and `speakers:` emissions:

```swift
let speakers = speakerCount(in: input.segments)
if speakers >= 2, hasAnyOverride(in: input) {
    let joined = (0..<speakers).map { i in
        input.speakerNames[i]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Speaker \(i + 1)"
    }.joined(separator: ", ")
    lines.append("participants: \(yamlScalar(joined))")
}
if speakers >= 2 {
    lines.append("speakers: \(speakers)")
}
```

Helpers `hasAnyOverride(in:)` and `String.nilIfEmpty` are private to the file.

**Rule detail:**

- Emitted only when `speakerCount >= 2` (same threshold as the existing `speakers:` field).
- Emitted only when at least one override key has a non-empty trimmed value — otherwise the line would be `participants: Speaker 1, Speaker 2` which duplicates the `speakers: 2` info.
- Fallback for each missing/empty index is `Speaker \(i + 1)`, in ascending index order.
- The joined string goes through `yamlScalar` so a name containing `:`, `#`, `,` etc. forces quoting.

**Note on ordering and count:** the outer loop iterates `0..<speakerCount`. If the DB has an override for an index beyond `speakerCount` (e.g. a re-diarization shrunk the speaker set), that override is silently ignored — the render only cares about speakers present in the segments.

### 4.5 `ExportInput` threading

```swift
public struct ExportInput: Equatable, Sendable {
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int?
    public let tags: [String]
    public let speakerNames: [Int: String]   // NEW — default [:]
    public let segments: [Segment]
}
```

`ExportInputBuilder.build(from recording: Recording)` adds `speakerNames: recording.speakerNames` to every `ExportInput(...)` construction site (same pattern as the tag-threading done for Copy-for-Prompt).

---

## 5. UI — `SpeakerNameEditor`

A new SwiftUI view rendered inside `TranscriptionDetailView`, below the title block and above the transcript body.

### 5.1 Visibility rule & speaker discovery

On first appearance the editor discovers which speaker indices exist in the recording by calling `ExportInputBuilder.build(from: recording)` and collecting the distinct non-nil `.speaker` values from the resulting `ExportInput.segments`. This is cheap — `ExportInputBuilder` already decodes the `.json` sibling on-demand for every export; it just does the same decode once on editor appear.

The editor is rendered only when this discovery returns a non-empty set of speaker indices. Un-diarized recordings (all segments have `.speaker == nil`) show nothing. Single-speaker diarized recordings show one row — the user can still name a solo dictation's sole speaker, even though the `participants:` front-matter field doesn't emit for `speakerCount < 2` (by design — the `speakers:` line is omitted in that case too).

### 5.2 Row list

Rows correspond to the distinct speaker indices present in the segments, in ascending order. Each row:

- Left: a fixed label `Speaker N` (1-based; the stable reference — never shows the override here, so the user always knows which speaker they're renaming).
- Right: a `TextField` pre-populated with the current override (empty when none).
- Placeholder text: `Name (e.g. Jason)`.

Layout uses `HarcDesign.Space` tokens and existing typography to match the rest of the detail pane.

### 5.3 State, commit, callback

**State:** `@State private var draftNames: [Int: String]` holds the in-progress edit. Initialised on `.onAppear` from `recording.speakerNames`, so typing doesn't fight a parent re-render.

**Commit (Enter or focus-loss on a field):**

1. Trim the committed field's value. If empty-trim, remove that index from `draftNames`; otherwise set it.
2. If `draftNames` differs from `recording.speakerNames`, call the upward callback `onSpeakerNamesChanged(draftNames)`.

**Callback wiring** — mirrors the existing `onRename` pattern already in `TranscriptionDetailView`:

```swift
public struct TranscriptionDetailView: View {
    let onRename: (String?) -> Void
    let onSpeakerNamesChanged: ([Int: String]) -> Void   // NEW
    // ...
}
```

The parent view (typically `AppDelegate`'s popover or `LibraryWindowController`'s detail pane) implements the callback: it calls `store.updateSpeakerNames(id:names:)` and updates the view-model's `Recording` snapshot so the next render bindings see the new names. This matches exactly how title edits are persisted today via `onRename`.

**Failure handling:** the callback is non-throwing to keep the UI simple. If the store write fails, the parent shows a single-line warning via the existing error-surface pattern (e.g. the `exportErrorMessage` state in `LibraryWindowRootView`). No modal.

---

## 6. Code architecture (file-level map)

**Extended — HarcStore:**

- `Recording.swift` — add `speakerNames: [Int: String]` stored property, default `[:]`, with `Codable` round-trip (mirrors the `tags` encode/decode).
- `RecordingStore.swift` — add `updateSpeakerNames(id: Int64, names: [Int: String]) async throws`. Empty dict → column set to NULL.
- `DatabaseMigrator+Harc.swift` — register migration `v5_speaker_names`, adds the column.

**Extended — HarcExport:**

- `ExportInput.swift` — add `speakerNames: [Int: String]` stored property, default `[:]`.
- `ExportInputBuilder.swift` — thread `recording.speakerNames` into every `ExportInput(...)` call.
- `MarkdownExporter.swift` — use `SpeakerLabel.displayLabel`.
- `DocxExporter.swift` — use `SpeakerLabel.displayLabel`.
- `PromptFrontMatter.swift` — emit `participants:` line per §4.4.

**New — HarcExport:**

- `SpeakerLabel.swift` — `enum SpeakerLabel { static func displayLabel(for:names:) -> String? }`.

**New — HarcUI:**

- `SpeakerNameEditor.swift` — the editor view.

**Extended — HarcUI:**

- `TranscriptionDetailView.swift` — insert `SpeakerNameEditor` between the title block and the transcript scroll view. Gain a new `onSpeakerNamesChanged: ([Int: String]) -> Void` callback in init, plumbed through to the editor. Existing call sites (`AppDelegate`, `LibraryWindowController`) pass a closure that calls `store.updateSpeakerNames` and refreshes the view-model's `Recording` snapshot — mirrors the existing `onRename` wiring.

**Unchanged:**

- `HarcCore/IPCRequest.swift`, `IPCResponse.swift` — speaker renaming is client-side only.
- `HarcSTT/*` — daemon never sees overrides.
- `HarcClient/*` — ChunkedTranscriber, HarcSTTClient, etc.
- `.txt` and `.json` sibling files on disk.
- `TranscriptEditor/*` views.

---

## 7. Testing

### 7.1 Pure unit — HarcExport

**`SpeakerLabelTests`:**

- `displayLabel(for: nil, names: [:])` → `nil` (un-diarized segment).
- `displayLabel(for: 0, names: [:])` → `"Speaker 1"` (fallback).
- `displayLabel(for: 0, names: [0: "Jason"])` → `"Jason"` (override hit).
- `displayLabel(for: 1, names: [0: "Jason"])` → `"Speaker 2"` (miss → fallback).
- `displayLabel(for: 0, names: [0: "  "])` → `"Speaker 1"` (empty-trim treated as absent).
- `displayLabel(for: 0, names: [0: "  Jason  "])` → `"Jason"` (trimmed).

**`MarkdownExporterTests` (new cases):**

- Diarized input + empty `speakerNames` → `Speaker 1: …\nSpeaker 2: …`.
- Diarized input + `{0: "Jason"}` → `Jason: …\nSpeaker 2: …`.
- Diarized input + `{0: "Jason", 1: "Amy"}` → `Jason: …\nAmy: …`.

**`PromptFrontMatterTests` (new cases):**

- `render` omits `participants:` when `speakerNames` is empty.
- `render` emits `participants: Jason, Amy` when both are overridden.
- `render` emits `participants: Jason, Speaker 2` for partial override.
- `render` does NOT emit `participants:` for single-speaker recordings (even with an override) — consistent with `speakers:` omission rule.
- `render` quotes `participants:` when a name contains `:` (e.g. `"Foo: Bar"` → `participants: "Foo: Bar, Amy"`).

**`ExportInputBuilderTests` (new):**

- `build` threads `recording.speakerNames` into `input.speakerNames` for all three branches (JSON-present, transcriptText fallback, empty).

### 7.2 HarcStore

**`RecordingStoreTests` (new cases):**

- Insert a recording with `speakerNames: [0: "Jason", 1: "Amy"]`, read back, assert round-trip.
- Insert with empty dict → column is NULL; read back → empty dict.
- `updateSpeakerNames(id:names:)` updates the column; subsequent fetch reflects the change.
- `updateSpeakerNames(id:names: [:])` nulls the column.

**Migration test:** at least one existing test that opens a fresh DB should pass (the additive column migration doesn't break any existing row). A targeted new test confirms the column exists post-migration.

### 7.3 UI — manual smoke

No automated UI tests (consistent with how `SpeakerNameEditor` will ship; SwiftUI view testing harness is out of scope for this project).

**Manual checklist (expanded in the plan):**

- Record a 2-speaker fixture. Open detail. Type "Jason" into Speaker 1, "Amy" into Speaker 2. Close & re-open detail. Confirm names persist.
- Copy for Prompt. Paste into a text editor. Confirm `Jason:`/`Amy:` in body and `participants: Jason, Amy` in front-matter.
- Clear Speaker 2's field. Copy for Prompt. Confirm `Jason:`/`Speaker 2:` in body and `participants: Jason, Speaker 2` in front-matter (partial override).
- Clear both fields. Copy for Prompt. Confirm `Speaker 1:`/`Speaker 2:` in body and the `participants:` line is GONE (no overrides → no line).
- Un-diarized recording. Open detail. Confirm the Speakers section is not rendered at all.

---

## 8. Error handling

- **Corrupt JSON in the column** (unlikely but possible from a downgrade/upgrade cycle): decode silently returns `[:]`. The render path falls back to `Speaker N` throughout. No user-facing error; the cost of losing rename data is low and the event is rare.
- **DB write failure on commit** from the editor: catch, surface a single-line warning under the editor (`"Couldn't save name — try again"`). Keep the user's typed value in the field so they can retry. No modal, no toast subsystem.
- **The diarizer emits a new speaker index after a re-run** (hypothetical; not a v1 flow): overrides for old indices survive, the new speaker index falls back to `Speaker N`. No crash, no data loss. This is why the dict shape is right for forward compatibility.

---

## 9. Open decisions captured

- **Column on `recordings`, not a side table.** Overrides are always joined with the recording, always edited together, have no independent lifecycle. `tags` uses the same pattern and is ergonomic. A separate table would add a FK + JOIN for zero benefit.
- **Dict, not array.** Handles sparse input naturally. Robust to re-diarization adding a new index.
- **JSON string keys get converted to Int** at decode time, with malformed keys silently dropped. Matches the forgiving defaults used elsewhere.
- **`participants:` only when overrides exist.** When all labels are the `Speaker N` default, the `speakers: N` line already communicates everything; emitting a verbose `participants: Speaker 1, Speaker 2` is noise for the LLM.
- **No write-back to `.json`.** Keeps the on-disk file objective — diarizer output, not user annotation. A third party loading the `.json` gets the same view regardless of who held the file.
- **Empty string = clear.** Matches text-field ergonomics; users don't need to learn a separate "delete this row" gesture.

---

## 10. Sequencing with Tier 1

- **#3 Copy for Prompt** — ✅ shipped. This spec fulfills the deferred `participants:` front-matter field that spec §2 explicitly blocked on Tier 1 #4.
- **#1 Auto-paste** — ✅ shipped. Auto-paste already uses `ExportService.promptString`, which will automatically pick up the new `participants:` line once this feature lands — no changes needed there.
- **#2 VAD gating** — ✅ shipped. Independent from speaker renaming; no interaction.
- **#4 Speaker renaming (this spec)** — last of Tier 1.
