# Copy for Prompt Design Doc

**Feature:** Promote clipboard content from plain text to a structured, LLM-paste-ready Markdown blob with YAML front-matter. Add a matching file export format.
**Date:** 2026-04-19
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Harc's north star is "transcribe → paste into an LLM." Today the clipboard carries bare transcript text. Two gaps:

- **No context for the LLM.** A raw transcript gives the model no idea what it's reading. The user ends up typing a preamble by hand ("This is a standup on 4/18 with Jason and Amy…") or accepting a weaker summary.
- **Asymmetric use cases.** Meetings and dictation-for-vibe-coding both benefit from machine-readable context — date, duration, tags, speaker count, title — but differently. A single structured blob serves both. The LLM interprets the context; Harc does not.

**User story (meeting).** "I stop a meeting recording. The clipboard already holds a block with date, duration, tags, and speaker-labelled body. I switch to Claude, paste, and say *'summarize decisions and action items'* — the model already knows what it's looking at."

**User story (vibe coding).** "I dictate a spec for an auth refactor. The clipboard holds the same shape — title *'auth refactor dictation'*, tags *'auth, refactor, Harc'*, no speaker labels (single-speaker). I paste into Claude Code and say *'turn this into a plan.'* The CLI reads the YAML header without complaint."

Harc authors no preamble, ships no templates, exposes no Settings surface. The blob is a passive structured signal. The LLM does the work.

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- A pure function `ExportService.promptString(for: Recording) -> String` that returns the prompt-formatted blob.
- Clipboard semantics: **the default Copy action copies the prompt-formatted blob**, not plain text. A secondary "Copy Plain Text" action remains available.
- A new `ExportFormat.prompt` case that writes the same blob to a `.prompt.md` file from the Library Export menu.
- YAML front-matter fields: `title`, `recorded`, `duration`, `tags`, `speakers`. Each omitted when empty/absent.
- Body identical to the existing `MarkdownExporter.render(input)` output.
- Tags flow via a new `ExportInput.tags: [String]` field, populated by `ExportInputBuilder` from `Recording.tags`.
- Unit tests for front-matter rendering (escaping, dates, durations, omitted fields) and for `promptString` composition.

**Out of scope / non-goals (v1):**

- **Harc-authored system preamble or templates.** Rejected: the LLM interprets context from the front-matter; the user owns their own system prompt.
- **Template editor, presets, or multi-template UX.** Rejected for the same reason. Zero configuration surface.
- **Participant names in front-matter** (`participants: Jason, Amy`). Blocked on Tier 1 #4 (Speaker renaming + persistence). Until then we emit `speakers: <count>` only.
- **Keyboard shortcuts for copy actions.** Deferred; likely handled alongside Tier 1 #1 (Auto-paste) or later.
- **Auto-paste integration.** That's Tier 1 #1's scope. `promptString` is the content source #1 will consume, but the wiring lives there.
- **Stripping or altering existing plain-text TXT sibling file.** The on-disk `HH-mm-ss.txt` stays raw — this spec only changes clipboard behavior and adds a new export format.

---

## 3. Output shape

A single blob, always the same shape:

```
---
title: Standup with Jason
recorded: 2026-04-19T14:32:00-07:00
duration: 47m
tags: standup, Jason, Harc
speakers: 2
---

Speaker 1: Morning. Any blockers from yesterday?
Speaker 2: The socket reconnect logic is still flaky under sleep.
Speaker 1: ...
```

### 3.1 Front-matter field rules

| Field | Source | Format | Omitted when |
|-------|--------|--------|--------------|
| `title` | `Recording.displayTitle` | YAML-escaped string | `displayTitle` is empty after trim |
| `recorded` | `Recording.startedAt` | ISO 8601 with local offset (`yyyy-MM-dd'T'HH:mm:ssXXX`) | never |
| `duration` | `endedAt - startedAt` | `<N>s` / `<N>m` / `<H>h <M>m` (see §3.2) | `endedAt == nil` |
| `tags` | `Recording.tags` (joined by `, `) | comma-separated YAML-escaped string | list is empty |
| `speakers` | count of distinct speakers in `ExportInput.segments` | integer | count < 2 (single-speaker or un-diarized) |

Field order in the block is fixed: `title`, `recorded`, `duration`, `tags`, `speakers`. Stable order makes tests deterministic and diffs readable.

### 3.2 Duration formatting

| Total seconds | Rendered |
|---------------|----------|
| 0 | `0s` |
| 1 – 59 | `<N>s` |
| 60 – 3599 | `<N>m` (integer minutes, truncated — `119s → 1m`) |
| ≥ 3600 | `<H>h <M>m` (no seconds at this scale) |

Rationale: human-glanceable, no LLM needs higher precision. Truncation over rounding because we have exact durations elsewhere if needed.

### 3.3 YAML escaping

Front-matter values are rendered as **plain scalars** when safe, **double-quoted scalars** otherwise. A value must be quoted if it:

- begins with a YAML indicator (`! & * - : ? { } [ ] , # | > ' " %  @  \``)
- contains `:` followed by a space
- contains `\n`, `\r`, or `\t`
- contains a leading or trailing space
- is empty after sanitization

Double-quoted escapes: `"` → `\"`, `\` → `\\`, `\n` → `\\n`, `\r` → `\\r`, `\t` → `\\t`. Control characters below `0x20` (other than already-escaped whitespace) are stripped — same policy as `MarkdownExporter.sanitize()`.

Tags are joined with `", "` (comma-space) *before* scalar decision. If any tag contains a reserved character, the entire `tags:` value is emitted quoted with the combined string as its content — we do not quote individual tags. Keeps the format a simple YAML string, not a list, which matches the one-line visual intent.

### 3.4 Blank line discipline

Between closing `---` and the first body line: exactly one blank line. Body ends with a single trailing `\n` (matches `MarkdownExporter` contract). If the body is empty, the blob is the front-matter block + one trailing newline. No other whitespace variations.

---

## 4. Code architecture

All changes are contained to the **HarcExport** target plus three call sites in **HarcUI**. No new targets, no new packages.

### 4.1 HarcExport changes

**Extended:** `ExportInput`

```swift
public struct ExportInput: Equatable, Sendable {
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int?
    public let tags: [String]          // NEW — default [] in init
    public let segments: [Segment]
}
```

`tags` defaults to `[]` in the initializer to keep existing call sites compiling. `ExportInputBuilder.build(from:)` populates it from `recording.tags` unchanged.

**New:** internal `PromptFrontMatter` renderer (`Sources/HarcExport/PromptFrontMatter.swift`).

```swift
enum PromptFrontMatter {
    static func render(_ input: ExportInput) -> String
    // Helpers (internal, tested directly):
    static func formatRecorded(_ date: Date) -> String
    static func formatDuration(_ seconds: Int) -> String
    static func yamlScalar(_ value: String) -> String  // plain or double-quoted
    static func speakerCount(in segments: [ExportInput.Segment]) -> Int
}
```

Produces the `---` … `---` block with no trailing blank line; composition is responsible for spacing.

**New:** `ExportService.promptString(for:)`:

```swift
public static func promptString(for recording: Recording) -> String {
    let input = ExportInputBuilder.build(from: recording)
    let header = PromptFrontMatter.render(input)
    let body = MarkdownExporter.render(input)
    if body.isEmpty { return header + "\n" }
    return header + "\n\n" + body
}
```

**Extended:** `ExportFormat`

```swift
public enum ExportFormat: Sendable {
    case markdown
    case docx
    case prompt             // NEW
    public var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .docx:     return "docx"
        case .prompt:   return "md"       // still Markdown; see §4.2
        }
    }
}
```

**Extended:** `ExportService.write(recording:format:to:)` — adds a `case .prompt: data = Data(promptString(for: recording).utf8)` branch. Same atomic write and `ExportError` paths as `.markdown`.

**Extended:** `ExportService.defaultDestination(for:format:)` — for `.prompt`, returns `<stem>.prompt.md` (not `<stem>.md`) to avoid clobbering a plain Markdown export in the same folder. Every other case unchanged.

### 4.2 Filename convention

`.prompt` writes files with extension `.md` (they are valid Markdown) but a **compound stem** `<HH-mm-ss>.prompt`, producing e.g. `14-32-00.prompt.md`. Rationale:

- Files open in any Markdown viewer without app-specific registration.
- The `.prompt` infix makes it unambiguous in `ls` which export was which.
- Users who want to rename on save still get a sensible default via `NSSavePanel.nameFieldStringValue`.

### 4.3 HarcUI wiring

**Changed:** `LibraryWindowRootView.swift`

- The `Export ▾` menu grows one item: `Export for Prompt…` — placed below `Export DOCX…` and above the `Divider()`.
- The existing top-level "Copy Markdown" button is renamed to **"Copy for Prompt"** and its action becomes `copyPromptString(rec)`.
- The `Export ▾` menu's existing "Copy Markdown" menu item is removed; the menu gains both **"Copy for Prompt"** and **"Copy Plain Text"** in the clipboard section.
- New private helpers:

```swift
private func copyPromptString(_ rec: Recording) {
    let s = ExportService.promptString(for: rec)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    exportErrorMessage = nil
}

private func copyPlainText(_ rec: Recording) {
    // ExportInput has everything we need — reuse to avoid re-reading disk.
    let input = ExportInputBuilder.build(from: rec)
    let text = input.segments.map { $0.text }.joined(separator: "\n\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    exportErrorMessage = nil
}
```

Plain text intentionally strips speaker labels — if you're pasting a snippet somewhere, you want the words, not the turn structure. If you want the turn structure, use "Copy for Prompt" or "Copy Markdown" via `ExportService.markdownString`. (Markdown-body-only is available as an action if we find we miss it; see §8.)

**Changed:** `TranscriptionDetailView.swift`

- The existing `Copy` button is renamed **"Copy for Prompt"** and its action calls `ExportService.promptString(for: recording)` and writes the result to the pasteboard.
- A secondary menu item (via `Menu` wrapper or chevron) exposes **"Copy Plain Text"** that puts the raw `transcript` string on the pasteboard.
- The existing "Paste" button's content source changes from `transcript` to `ExportService.promptString(for: recording)`, matching the clipboard principle. The mechanics (`FrontmostAppPaster.copyAndPaste`) are unchanged. Preference toggles, toast feedback, and target safety remain #1's scope.

Note: `TranscriptionDetailView` already receives `recording: Recording` (it renders title, tags, etc.), so `ExportService.promptString(for: recording)` wires in directly — no new parameters or overloads needed.

No other views change. No Settings surface. No new hotkeys. No new preferences.

---

## 5. Data flow

```
Recording (HarcStore)
   │
   ├──▶ ExportInputBuilder.build(from:)                (HarcExport)
   │        reads jsonPath if present, else transcriptText
   │        populates tags from recording.tags
   │
   └──▶ ExportInput
           │
           ├──▶ PromptFrontMatter.render                (HarcExport internal)
           │        title / recorded / duration / tags / speakers
           │
           └──▶ MarkdownExporter.render                 (existing, unchanged)
                    speaker-labelled body or plain paragraphs
                        │
                        ▼
                 ExportService.promptString             ◀── "Copy for Prompt"
                        │                                  ◀── "Export for Prompt…"
                        │                                  ◀── (future) Auto-paste on stop
                        ▼
                 String → NSPasteboard.general
                        or → Data → URL (atomic write)
```

Key properties:

- **No new disk reads.** `ExportInputBuilder` already loads `jsonPath`. `PromptFrontMatter` is a pure function over `ExportInput`.
- **Body stays canonical.** Every exporter that shows a transcript (Markdown file, DOCX, Prompt blob) starts from the same `MarkdownExporter.render(input)` output. A future bug fix in speaker-collapse logic flows everywhere.
- **Composable.** `promptString` is pure and testable; the UI just moves strings to the pasteboard or the filesystem.

---

## 6. Error handling

Prompt blob generation cannot fail:

- `ExportInputBuilder.build` already swallows missing/unreadable JSON and falls back to `transcriptText`, else an empty segments array.
- `MarkdownExporter.render` handles empty segments (returns `""`).
- `PromptFrontMatter.render` always succeeds — worst case, every field is omitted except `recorded` (which always has a value).

Therefore `ExportService.promptString` is infallible. No new error type, no new `ExportError` cases.

File writes for `.prompt` format reuse the existing `.markdown` error paths in `ExportService.write`:

- `ExportError.diskFull` (`NSFileWriteOutOfSpaceError`)
- `ExportError.permissionDenied(url:)` (`NSFileWriteNoPermissionError`)
- `ExportError.writeFailed(url: underlying:)` for everything else

Clipboard writes (`NSPasteboard.setString`) are treated as infallible in AppKit; no error path there.

---

## 7. Testing

All tests live in `Tests/HarcExportTests`. Runner: Swift Testing.

### 7.1 `PromptFrontMatterTests`

Direct tests on each helper:

- **`formatRecorded`** — fixed `Date` → expected ISO 8601 with local offset. Use `TimeZone(identifier: "America/Los_Angeles")` (override via test-local calendar) to guarantee determinism. One test per of UTC, +offset, DST-boundary.
- **`formatDuration`** — table-driven: `[0, 1, 59, 60, 119, 3599, 3600, 5400, 86400]` → `["0s","1s","59s","1m","1m","59m","1h 0m","1h 30m","24h 0m"]`.
- **`yamlScalar`** — plain case (`"Standup with Jason"` → `Standup with Jason`), quoted cases (values with `:`, `"`, `\n`, leading space, empty string), escaping (`"He said \"hi\""` → `"He said \"hi\""`).
- **`speakerCount`** — `[]` → 0; `[.init(speaker: nil, text: "a")]` → 0; `[.init(speaker: 0, text: "a"), .init(speaker: 1, text: "b")]` → 2; duplicate ids coalesced.
- **`render` integration** — full `ExportInput` → expected multi-line block with fields in fixed order; omitted fields verified for empty title / nil duration / empty tags / speakers<2.

### 7.2 `ExportServiceTests`

- **`promptString composes header + blank line + body`** — builds a fixture `Recording`, asserts `promptString == PromptFrontMatter.render(input) + "\n\n" + MarkdownExporter.render(input)`.
- **`promptString with empty body` — header + single trailing newline, no double newline.**
- **`write .prompt format`** — writes a fixture Recording to a temp URL, reads it back, confirms bytes equal `Data(promptString.utf8)`.
- **`defaultDestination for .prompt ends with .prompt.md`** and sits in the same folder as the `.wav`.

### 7.3 `ExportInputTests`

- **`ExportInputBuilder copies tags from Recording.tags`** — new assertion on the existing builder-integration test (or a new focused test if that one's too broad).

### 7.4 Manual smoke (checklist in the plan, not the spec)

- Stop a recording, open Library, click **Copy for Prompt**, paste into a text editor → verify shape.
- Click **Copy Plain Text** → verify no YAML, no `Speaker N:` prefixes.
- Export menu → **Export for Prompt…** → save → open file → verify shape.
- Repeat on a single-speaker recording → confirm `speakers:` omitted and body has no labels.
- Repeat on a recording with tags containing `:` → confirm `tags:` is quoted correctly.

---

## 8. Open decisions captured

- **Plain-text copy drops speaker labels.** Alternative: keep labels, because users may want to paste a diarized snippet into a non-Markdown tool. Decision: drop labels for v1 — "Copy Plain Text" is for quoted-snippet use, and structure-preserving copy is what "Copy for Prompt" and Markdown exports are for. Revisit if anyone complains.
- **Duration truncates instead of rounding.** `119s` renders as `1m`, not `2m`. Chosen for determinism in tests and because the user can always check the recording detail for exact numbers.
- **No `participants:` field yet.** Blocked on Tier 1 #4. When speaker names persist, we emit `participants: Jason, Amy` and keep `speakers: 2` as well.
- **"Copy Markdown" is gone from Library UI.** The rich blob contains the same body; keeping three clipboard actions in one menu is UI noise. If users need body-only-no-frontmatter on the clipboard we can add it back without a spec. Reverting is cheap.
- **Front-matter field order is alphabetic-by-intent, not alphabetic-by-key.** `title` → `recorded` → `duration` → `tags` → `speakers` is the mental order a reader scans. Tests pin it.

---

## 9. Sequencing with Tier 1

- **This spec (#3) ships first.** Produces `promptString` and the clipboard semantics.
- **#1 Auto-paste** lands next. It adopts `promptString` as the content source on recording-stop — no additional work in that spec beyond swapping the argument to `FrontmostAppPaster.copyAndPaste`. The preference toggle, target safety, and toast belong in #1's spec.
- **#2 VAD gating** is independent — no interaction.
- **#4 Speaker renaming** interacts: once landed, `PromptFrontMatter` gains a `participants:` field and the body substitutes persisted names. Small follow-up in #4's spec, not here.
