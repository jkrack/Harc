# Structured Exports Design Doc

**Feature:** On-demand Markdown and DOCX export of transcripts from the Library.
**Date:** 2026-04-19
**Status:** draft — ready for implementation

---

## 1. Problem & user story

Harc already writes three sibling files for every recording (`.wav`, `.txt`, `.json`) and drops the plain transcript onto the clipboard on stop. That covers the dominant paste-into-LLM flow, but it leaves two gaps:

- **Sharing.** Users frequently want to send a transcript to a colleague in a format that renders as a document, not a plain-text blob. DOCX is the lowest-common-denominator for Slack/email/Notion/Word.
- **Structure.** When the transcript has diarization, pasting `Speaker 1: / Speaker 2:` alternating lines into an LLM produces demonstrably better summaries than a run-on paragraph. A minimal Markdown export formalises that shape and makes it easy to paste into anything that can render Markdown (Notion, Obsidian, Cursor/ChatGPT, etc.).

**User story.** "From the Library, I pick a recording, click Export, and choose Markdown or DOCX. The file lands in my existing Harc folder next to the other siblings, named consistently. If I want to share via clipboard I can grab the Markdown directly."

The user explicitly rejected auto-writing `.md` / `.docx` on every stop — too many files, too speculative. Export is a deliberate user action.

---

## 2. Scope (v1) and non-goals

**In scope (v1):**

- Per-recording Export button in `LibraryWindowRootView` (right-hand detail pane).
- Two output formats: **Markdown (.md)** and **DOCX (.docx)**.
- Markdown shape: speaker-prefixed flat lines; plain paragraphs when diarization is absent. No front matter, no timestamps.
- Default save location: the existing recording folder (`YYYY/YYYY-MM-DD/HH-mm-ss.{md,docx}`) with a **Save As…** override.
- A **Copy Markdown** convenience action that writes the Markdown string onto `NSPasteboard.general` without touching disk.
- Pure, testable renderer functions with fixture-based unit tests.

**Out of scope / non-goals (v1):**

- SRT / VTT captioning formats. The use case is summarisation/paste, not video subtitling. Revisit if a user explicitly asks.
- Batch export (multi-select → export all). Deferred.
- Rich Markdown with timestamps, headings, front-matter YAML. We have JSON for anything that needs structure; Markdown is optimised for paste-into-LLM density.
- PDF, RTF, HTML. If RTF becomes cheap once we have the DOCX pipeline (they share `NSAttributedString`), it can follow; not v1.
- Custom DOCX templates or styling hooks.

---

## 3. Architecture

### 3.1 Package placement

A new library target, **`HarcExport`**, is added to `Package.swift`:

```
.target(
    name: "HarcExport",
    dependencies: ["HarcCore", "HarcStore"]
),
.testTarget(
    name: "HarcExportTests",
    dependencies: ["HarcExport", "HarcCore"],
    resources: [.copy("Fixtures")]
),
```

**Why a new module rather than folding into `HarcCore` or `HarcStore`:**

- `HarcCore` is IPC-only types. It is linked into the `harc-stt` daemon executable. Pulling `AppKit`/`NSAttributedString` into `HarcCore` would contaminate the daemon with UI frameworks it never uses, for no reason.
- `HarcStore` is GRDB + NLTagger. Export has no DB dependency of its own — it takes a `Recording` (or just its `jsonPath`) and emits a byte stream.
- A dedicated `HarcExport` keeps the renderers pure and independently testable, and gives the DOCX path a clean home for its AppKit import.

`HarcExport` depends on `HarcCore` for `TranscribeResult` / `SpeakerSegment` / `Word`, and on `HarcStore` for `Recording` (so the UI layer can pass a `Recording` without reaching back into the filesystem itself).

### 3.2 Module shape

```
Sources/HarcExport/
  ExportInput.swift        // value type passed into renderers
  MarkdownExporter.swift   // pure fn: ExportInput -> String
  DocxExporter.swift       // pure fn: ExportInput -> Data (AppKit)
  ExportService.swift      // façade: load .json, render, write/copy
  ExportError.swift        // typed errors
```

All renderers are **pure functions** over `ExportInput`. `ExportService` is the only piece that touches the filesystem or pasteboard; it is a thin coordinator so the renderers can be exercised without any I/O in tests.

### 3.3 Control flow

```
Library UI
  └─▶ ExportService.export(recording:, format:, destination:)
        ├─ load SessionTranscript JSON from recording.jsonPath
        │     └─ fallback: transcriptText-only input if .json absent
        ├─ build ExportInput
        ├─ MarkdownExporter.render(input) / DocxExporter.render(input)
        └─ write bytes to chosen URL (or return bytes for clipboard)
```

---

## 4. Input contract

`ExportInput` is the canonical shape feeding the renderers. It isolates the renderers from `SessionTranscript` / `Recording` so we can extend either side without churning the other.

```swift
public struct ExportInput: Equatable, Sendable {
    public let title: String          // Recording.displayTitle, used in DOCX only
    public let startedAt: Date        // metadata, DOCX only
    public let durationSeconds: Int?  // metadata, DOCX only
    public let segments: [Segment]    // the body

    public struct Segment: Equatable, Sendable {
        public let speaker: Int?      // nil when diarization produced no label
        public let text: String       // already trimmed; non-empty
    }
}
```

**How `ExportInput.segments` is built from the on-disk `.json`:**

`SessionTranscript` gives us `joinedText: String`, `words: [Word]` (with `startMs`/`endMs`), and `speakers: [SpeakerSegment]` (speaker id + time range). There is no pre-baked "speaker-attributed line" structure, so we compute one:

1. If `speakers.isEmpty` **or** all words have no speaker overlap, emit a single `Segment(speaker: nil, text: joinedText.trimmed)`.
2. Otherwise, walk the `words` list; assign each word to the `SpeakerSegment` whose `[startMs, endMs]` most-overlaps the word's midpoint. Concatenate contiguous runs of same-speaker words into a single `Segment`.
3. **Collapse rule:** consecutive segments with the same `speaker` id are merged (can happen across chunk boundaries).
4. **Empty-segment guard:** drop any resulting segment whose text trims to empty.

Speaker ids are stable integers. The renderer maps them to labels (`Speaker 1`, `Speaker 2`, …) — we don't ship user-editable speaker names in v1.

**Fallback when `.json` is missing or unreadable:** if `recording.jsonPath` is nil, or the file can't be decoded, fall back to `Recording.transcriptText` as a single `speaker: nil` segment. The export still works, just without speaker attribution. This covers old rows and rows where the STT daemon failed before sibling-write.

---

## 5. Markdown renderer

**Output shape — diarized:**

```
Alex: We should ship this next week.
Morgan: Agreed, let's scope the dependencies.
Alex: I'll file the tickets tonight.
```

**Output shape — no diarization (single or zero speakers):**

```
We should ship this next week. Agreed, let's scope the dependencies. I'll file the tickets tonight.
```

That is: a single paragraph containing the joined text. If `joinedText` contained explicit paragraph breaks, we preserve them. The minimal-Markdown choice is deliberate — front matter, timestamps, and headings all risk confusing an LLM or bloating a paste.

### 5.1 Speaker-prefix logic

```
for each segment in input.segments:
    if segment.speaker is nil:
        append segment.text
        append "\n\n"   # paragraph break
    else:
        label = "Speaker \(segment.speaker + 1)"   # 0-indexed → 1-indexed
        append "\(label): \(segment.text)\n"       # single newline between turns
```

Rationale for the 0→1 shift: FluidAudio returns `speaker` as a 0-based index; presenting "Speaker 0" as a label looks like a bug.

### 5.2 Edge cases

| Case | Behaviour |
|---|---|
| `segments` is empty | Emit a single empty line; `ExportService` still writes a file (caller's explicit action). No throw. |
| A single segment, `speaker` = nil | Emit the text followed by a newline. No prefix. |
| A segment's `text` is whitespace-only | Already filtered out when building `ExportInput`. Defence-in-depth: skip in renderer. |
| Only one distinct speaker across all segments | Still prefix — the user asked for diarized output by turning diarization on. Honour it. |
| Very long transcripts (hour-plus meetings) | Streaming isn't needed; even a 2-hour transcript is well under 1 MB of text. Build in a single `String` and flush once. |

### 5.3 Escaping

Markdown is permissive, but a handful of characters break common renderers or confuse LLMs. Policy for v1:

- **Do not escape `*`, `_`, `` ` ``, `[`, `]`, `#`.** These appear naturally in speech transcripts ("C#", "that's a *must*", "the #design channel") and over-escaping creates more confusion than it prevents in a plain-paragraph document.
- **Normalise line endings** to `\n`. Strip `\r`.
- **Strip NUL / control chars** (`\0`-`\x1F` except `\n` and `\t`). Cheap defence against malformed audio → transcript edge cases.
- **Trim trailing whitespace** on each segment.

Document this decision in the renderer's doc comment so a future reader knows it's deliberate.

---

## 6. DOCX renderer

**Chosen path: `NSAttributedString` → `DocumentType.officeOpenXML`.** Native, zero third-party dependencies, ships in AppKit on every macOS target we care about (14+).

### 6.1 Why this path over alternatives

| Option | Verdict |
|---|---|
| **`NSAttributedString.data(from:documentAttributes:)` with `DocumentType.officeOpenXML`** | **Chosen.** Zero deps, tested-path on Apple, adequate for speaker-prefixed runs + paragraph styles. Failure mode is a thrown error we can surface. |
| Third-party Swift DOCX writer (e.g. `ZIPFoundation` + hand-rolled OOXML) | Rejected for v1. More code and a new dep for a format whose fidelity requirements here are tiny (paragraphs + bold labels). Reconsider if `officeOpenXML` output proves broken in Word/Pages in manual testing. |
| AppleScript → Pages/Word | Rejected. Fragile, requires the app installed, breaks "fully local, no side-effects." |
| Write `.docx` as a ZIP of hand-crafted XML | Rejected for v1. High surface area; we'd re-invent what `NSAttributedString` already does. |

The one concrete risk is that `DocumentType.officeOpenXML` has historically produced `.doc` (old Word binary) in some macOS releases when given certain attribute dictionaries. Verify in the first implementation task that the bytes open cleanly in both Word and Pages. If they don't, fall back to **`DocumentType.rtf`** for v1 (same API, battle-tested output, `.rtf` opens in Word and Pages natively) and defer true DOCX.

### 6.2 NSAttributedString assembly

```
Title           — 18pt semibold
Started + duration — 11pt secondary label grey, one line
(blank paragraph)
<speaker segments>…
```

For each segment:

- If `speaker != nil`: a paragraph whose first run is the label (`Speaker 1: `) in **semibold**, followed by a regular-weight run of the text.
- If `speaker == nil`: a regular-weight paragraph containing just the text.

Paragraph style: `paragraphSpacing = 6`, `lineHeightMultiple = 1.15`. Font: `NSFont.systemFont(ofSize: 12)` regular / 12 semibold / 18 semibold for the title. No colour — stays readable after paste into any doc. No custom fonts (shipped, portable).

### 6.3 Failure modes

`NSAttributedString.data(from:documentAttributes:)` throws. Wrap as `ExportError.docxRenderFailed(underlying:)`. UI surfaces a banner "Export failed — couldn't render DOCX. Try Markdown instead." Do **not** silently fall back to a different format — the user picked DOCX and silently swapping it is worse than an error.

---

## 7. UI integration

### 7.1 Where the button lives

`LibraryWindowRootView.detailContent(for:)` — the right-hand detail pane that already shows "FILE DETAILS", "AI SUMMARY", and the play button. Add an **Export** action group below "AI SUMMARY":

```
[ Export ▾ ]    [ Copy Markdown ]
```

Using a `Menu` (SwiftUI) for the dropdown:

```
Export ▾
 ├─ Export Markdown…
 ├─ Export DOCX…
 └─ Copy Markdown
```

The `…` on the two file formats matches macOS convention for "opens a dialog" — we show a standard `NSSavePanel` pre-populated with the sibling path (`HH-mm-ss.md` / `HH-mm-ss.docx` in the recording's day folder). Users can accept the default by hitting Return, or pick a different location. "Copy Markdown" is destinationless and is the fast path for paste-into-LLM.

Styling: re-use `HarcDesign.Font.bodyMd` + `Color.harcPrimary` for the button tint; same treatment as the existing "Read Full Transcript →" link.

### 7.2 NSSavePanel configuration

- `allowedContentTypes = [.init(filenameExtension: "md")!]` (or `docx`).
- `nameFieldStringValue = "HH-mm-ss.md"` (from the recording's wav stem).
- `directoryURL = recording.wavPath.parent` — the existing sibling folder, not the destination root. Keeps the user in context.

### 7.3 Copy Markdown

Writes to `NSPasteboard.general` via `clearContents()` + `setString(_:forType: .string)`. Shows a brief toast ("Markdown copied") — re-use whatever pattern the existing `FrontmostAppPaster` uses for stop-paste feedback, or a simple `.task`-scoped `@State` banner if no toast system exists yet.

---

## 8. Error handling

All `ExportService` calls are `async throws` with a typed `ExportError`:

```swift
public enum ExportError: Error, Sendable {
    case transcriptJSONUnreadable(path: String, underlying: Error)
    case docxRenderFailed(underlying: Error)
    case writeFailed(url: URL, underlying: Error)
    case permissionDenied(url: URL)
    case diskFull
}
```

| Failure | UI response |
|---|---|
| Disk full / no space | Banner: "Export failed — not enough disk space." No retry prompt. |
| Permission denied at target folder | Banner: "Export failed — Harc can't write to that folder. Try Save As…" |
| Overwrite existing file | `NSSavePanel` handles the confirm dialog natively; we don't second-guess. For the default-destination no-dialog path (future), we must pre-check `FileManager.fileExists` and prompt. In v1, **the default path always goes through `NSSavePanel`**, so the OS prompt covers it. |
| Transcript JSON missing/corrupt | Silent fallback to `Recording.transcriptText` (documented in §4). |
| DOCX render fails | Banner: "Couldn't export DOCX. Try Markdown." (No silent format fallback.) |

All banners are non-blocking — the user can try again.

---

## 9. Testing

**Unit tests (`HarcExportTests`):**

- `MarkdownExporterTests`
  - Diarized input with 3 speaker turns → expected flat output.
  - Single speaker across all segments → still prefixed.
  - Zero-speaker input (segments all `speaker: nil`) → plain paragraph.
  - Empty `segments` → empty-string output, no crash.
  - Segment text with `*`, `_`, `#` characters → passes through unescaped (regression test on the "don't escape" decision).
  - Segment text containing `\r\n` → normalised to `\n`.
  - Control characters (`\x00`, `\x01`) → stripped.
  - Speaker id `0` → label "Speaker 1".

- `DocxExporterTests`
  - Happy path: three-segment diarized input produces a non-empty `Data` blob that starts with the ZIP magic bytes `PK\x03\x04` (confirms it's a real `.docx`, not a stray `.doc` binary or RTF).
  - Writes through `NSAttributedString` → bytes decode back into an `NSAttributedString` with the same plain-text content.
  - Empty input → valid (minimal) `.docx`, no throw.

- `ExportInputBuilderTests`
  - Fixture `.json` with three speakers → correct segment collapsing.
  - Fixture `.json` with `speakers: []` → one `speaker: nil` segment.
  - Missing `.json`, `transcriptText` present → falls back to single-segment input.
  - Missing `.json` AND `transcriptText: nil` → empty input, renderer emits empty-but-valid output.

**Fixtures** live at `Tests/HarcExportTests/Fixtures/`:

- `three-speakers.json` (a hand-written `SessionTranscript` with ~6 words and 3 speakers)
- `single-speaker.json`
- `no-diarization.json` (speakers array empty)

**Manual testing (not automated in v1):**

- Export a real hour-long meeting recording as DOCX, open in Word, confirm paragraphs + bold speaker labels render.
- Same, open in Pages.
- Same, open in TextEdit (rich text).
- Copy Markdown, paste into Claude/ChatGPT, confirm speaker turns survive.

---

## 10. Future work

- **SRT / VTT export.** Natural extension once someone asks for captioning. `Word` timestamps are already in `SessionTranscript.words`. Pure renderer over `[Word]`, no new module.
- **Batch export.** Select N rows in the Library table → "Export all as Markdown" → zip or folder. Needs a progress UI and a cancellation path.
- **User-editable speaker names.** Replace `Speaker 1`/`Speaker 2` with "Alex"/"Morgan" via a rename UI in the detail pane. DB column on `Recording`, stored as `[Int: String]`.
- **PDF export.** `NSAttributedString` already knows how to render to PDF via `NSPrintOperation`. Low-effort if a user asks.
- **Auto-export on stop.** Preference toggle: "Also write .md alongside .wav/.txt/.json." Reconsider only if users actively want it; for now the on-demand model beats file sprawl.
- **Templates / front-matter.** YAML front matter with metadata for Obsidian-style tools. Opt-in preference.

---

## Appendix A — Open questions flagged during spec

- **Is `DocumentType.officeOpenXML` reliable in current macOS 14/15?** Verified in Task 3 (manual check). If broken, v1 falls back to `.rtf`.
- **Should "Copy Markdown" also show in the right-click context menu of the Library table?** Probably yes in a follow-up; v1 keeps it only on the detail pane to avoid the "batch export" ambiguity of right-clicking a selection.
- **Naming collisions when the user saves over an existing sibling?** `NSSavePanel` handles confirm. No special code.
