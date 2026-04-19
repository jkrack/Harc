# Custom Vocabulary — Design Doc

- **Date:** 2026-04-19
- **Status:** Proposed
- **Scope:** Post-processing pass that rewrites newly-transcribed text using user-defined `from → to` replacement rules.
- **Related:** `docs/superpowers/plans/2026-04-19-custom-vocabulary-plan.md` (implementation), `Sources/HarcClient/TranscriptWriter.swift` (write path), `Sources/HarcUI/SettingsView.swift` (Processing tab home).

---

## 1. Problem & User Story

Parakeet TDT 0.6B v3 (via FluidAudio) is a frozen Core ML model — it can't be fine-tuned, and we have no LoRA/prompt hook to bias decoding toward the user's jargon. In practice that means:

- Names are mis-spelled (`"Arakeet"` instead of `"Parakeet"`, `"Sara"` vs `"Sarah"`).
- Product names get phonetically mangled (`"Clawed"` → `"Claude"`, `"Jeera"` → `"Jira"`).
- Internal terminology is never right first time (`"oh kay are"` → `"OKR"`).

Every user hits the same five or ten bad tokens for their specific vocabulary. They want to fix them **once** and have every subsequent transcript come out clean.

### User story

> As a meeting-heavy user, I want to teach Harc that `"Arakeet"` should always become `"Parakeet"` so the transcript I paste into my LLM doesn't need hand-editing.

### Success metric

A transcript that contains 5+ occurrences of a known-bad token is fixed by a single vocabulary entry; the user never sees the wrong spelling again on that machine.

---

## 2. Scope (v1) and Non-Goals

### In scope

- A **Vocabulary** — an ordered list of `{ from, to }` string pairs, edited in Settings → Processing.
- **Case-insensitive, word-boundary-aware** replacement applied to newly-transcribed text.
- **Single-word AND multi-word phrases** both supported on both sides (`"oh kay are"` → `"OKR"`, `"Sara"` → `"Sarah"`).
- **Case preservation** — if the source token was all-caps or Title-Case, the replacement reflects that (`"ARAKEET"` → `"PARAKEET"`, `"arakeet"` → `"Parakeet"` if the rule target was `"Parakeet"`). See §6 for exact rules.
- Applies to:
  - `.txt` sibling file (what the user pastes into the LLM).
  - `.json` sibling — both the top-level `joinedText` and each `chunks[*].text`.
  - `Recording.transcriptText` stored in SQLite (so full-text search hits the corrected string).
- Runs **per completed chunk** at chunk-boundary + **once more** on the assembled final text, so durability is preserved and the live preview in the popover also shows corrected text.

### Out of scope (v1)

- **Retroactive rewrites.** Existing recordings are left alone. A future "Apply to library" action can iterate the store; we explicitly don't do it now because rewriting on-disk `.txt`/`.json` is a destructive op that deserves its own UX.
- Regex or wildcards. Plain string only; the field rejects regex-special characters with an advisory toast.
- Phonetic / fuzzy matching (Soundex, edit-distance). Nice-to-have, but v1 ships plain word-boundary replace.
- Word-timing adjustments. If `"oh kay are"` (3 NLP tokens) collapses to `"OKR"` (1 token), we do not re-stitch `words[].startMs/endMs` — the `words` array remains the raw model output. Paste-ready `.txt` is the product surface; word-level timing is a debug artifact.
- Per-profile vocabularies (work vs. personal). One global list in v1.
- Import/export of vocabulary files. Nice follow-up.

### Non-goals (permanent)

- Cloud sync. Vocabulary stays local, same constraint as the rest of Harc.

---

## 3. Architecture

### Where the code lives

New module: `Sources/HarcClient/VocabularyReplacer.swift`.

**Why HarcClient.** The replacement pass is a transcription-pipeline concern, not a storage or UI concern. HarcClient already owns the chunked transcription pipeline (`ChunkedTranscriber`, `TranscriptAssembler`, `TranscriptWriter`). A transcript rewriter is the most natural neighbor. Keeping it out of HarcStore means the daemon/client flow doesn't grow a GRDB dependency.

**Storage lives in HarcUI.** The vocabulary itself is a user preference, edited from Settings. It's persisted via `HarcPreferences` (UserDefaults, JSON-encoded array). The replacer is constructed with a snapshot of rules — it doesn't know about UserDefaults. See §4 for the rationale vs. GRDB.

### Hook points in the existing pipeline

```
           ┌───────────────────────┐
 WAV chunk ─►│ daemon.transcribe │──► ChunkResult.text (raw)
           └───────────────────────┘
                    │
                    ▼
        ┌──────────────────────────┐
        │ VocabularyReplacer.apply │  ← new
        └──────────────────────────┘
                    │
                    ▼
         TranscriptAssembler.add(ChunkResult)  (text is already cleaned)
                    │
                    ▼
       transcriber.finalize → SessionTranscript
                    │
                    ▼
        ┌────────────────────────────┐
        │ VocabularyReplacer.apply    │  ← new (idempotent belt+braces pass)
        │ on joinedText              │
        └────────────────────────────┘
                    │
                    ▼
            TranscriptWriter.writeSiblings  (writes cleaned .txt / .json)
                    │
                    ▼
           AppDelegate → store.upsert (cleaned text)
           AppDelegate → pasteboard   (cleaned text)
```

The per-chunk pass is the primary one — it means the popover live-preview, the pasteboard text, and the written files all see the same corrected text without doing the work twice. The finalize-time pass is a defensive second pass in case `joinedText` ever diverges from `chunks.map(\.text).joined` (e.g. future de-dup at chunk boundaries). Replacement is idempotent by construction, so running it twice is free.

### Dependency injection

`ChunkedTranscriber.init` gains an optional `vocabulary: Vocabulary = .empty` parameter. `RecordingSession` passes the current `HarcPreferences.vocabulary` snapshot at construction time. A recording started with one vocabulary uses that vocabulary for its entire duration; editing vocabulary mid-recording does not affect the in-flight session. This matches the existing pattern for `diarize` and `chunkDurationSeconds`.

---

## 4. Data Model

### `VocabularyEntry` schema

```swift
public struct VocabularyEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: String       // what the model says
    public var to: String         // what the user means
    public var enabled: Bool      // per-row toggle; default true
    public var createdAt: Date
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public var entries: [VocabularyEntry]
    public static let empty = Vocabulary(entries: [])
}
```

- `from` and `to` are both trimmed of leading/trailing whitespace before save. Internal whitespace is preserved (required for multi-word phrases).
- `enabled` lets a user disable a rule without deleting it — useful for experimenting.
- `createdAt` is kept purely for debugging; the UI does not expose it in v1.

### Persistence choice: `HarcPreferences` (UserDefaults) — NOT SQLite

**Chosen: JSON-encoded `Vocabulary` under `UserDefaults` key `harc.vocabulary`.**

Reasoning:

| Criterion | UserDefaults / HarcPreferences | SQLite / HarcStore |
|---|---|---|
| Size envelope | Realistic ceiling ~200 entries × ~50 bytes = 10 KB. UserDefaults handles this fine. | Overkill — no query dimension. |
| Query shape | Always read all, in order. No WHERE, no JOIN. | SQL adds nothing. |
| Edit pattern | SwiftUI list editing with `@Published`. | Would need a view model layer mediating GRDB. |
| Migration | JSON `Codable` — trivial. | Alembic-style migration for each schema change. |
| Concurrency | Main-thread only (edited from Settings UI). | Already-serialized actor, but more machinery. |
| Fit with existing code | Mirrors `diarize`, `chunkDurationSeconds`, `destinationPath`. | Would be the odd one out for a "settings" value. |

SQLite is the right tool when we have a library of things you query. Vocabulary is a settings-scoped list that's read as a whole, atomically, on every transcription. UserDefaults is the right scale.

**If vocabulary ever grows** — per-project/profile vocabularies, import from shared team list, etc. — it graduates to HarcStore with a proper `vocabulary_entries` table. That's a future migration, not a day-one cost.

### HarcPreferences surface

```swift
@Published public var vocabulary: Vocabulary {
    didSet { persistVocabulary() }
}
```

Mutation helpers live on `HarcPreferences`: `addEntry`, `updateEntry`, `deleteEntry(id:)`, `toggleEntry(id:)`, `moveEntries(fromOffsets:toOffset:)`. These wrap an array mutation + re-assignment of `vocabulary`, which fires `didSet`. Each write is atomic (a full JSON re-encode).

---

## 5. Pipeline Placement

### Which stages get rewritten

| Artifact | Rewritten? | Where |
|---|---|---|
| Per-chunk `ChunkResult.text` | Yes | `ChunkedTranscriber.processChunk` before `assembler.add` |
| `TranscriptUpdate.joinedTextSoFar` (popover live preview) | Yes (follows from above — it's built from already-clean chunks) | N/A — free |
| `SessionTranscript.joinedText` | Yes (idempotent re-pass) | `ChunkedTranscriber.finalize` → inside `TranscriptAssembler.finalize` wrapper, or immediately after |
| `.txt` sibling file | Yes (it's written from `joinedText`) | `TranscriptWriter.writeSiblings` (no change; it reads already-clean input) |
| `.json` sibling file — `joinedText` | Yes | Same — input is clean |
| `.json` sibling file — `chunks[*].text` | Yes | Same — chunks were cleaned before assembly |
| `.json` sibling file — `words[]`, `speakers[]` | **No** | Out of scope; word text is phonetic timing-anchored, re-stitching is a rabbit hole |
| `Recording.transcriptText` (SQLite, drives FTS) | Yes | Already clean — it's read from the cleaned `.txt` |
| Pasteboard auto-paste | Yes | Already clean — reads cleaned `.txt` |

### Why chunk-boundary + final, not just final

- **Preview quality.** The popover shows `joinedTextSoFar` as chunks arrive. If we only clean at finalize, users watch `"Arakeet"` scroll by for an hour then briefly see it become `"Parakeet"` when they hit stop. Feels broken.
- **Paste latency.** `stopRecording` writes `.txt` and hands it to the pasteboard within the same main-thread hop. Doing the cleanup inline with the finalize is fine because it's an O(chunks × rules) string op on already-built text — negligible on meeting-sized transcripts.
- **Chunk boundary risk.** A multi-word rule like `"oh kay are"` → `"OKR"` could straddle a chunk boundary (`"...oh kay"` at end of chunk N, `"are so..."` at start of chunk N+1). This is a genuine limitation of the per-chunk approach. Mitigation: run the final-pass across `joinedText` — rules match across the rejoined text even if the chunks split them. This is the main reason we do both passes.

---

## 6. Word-Boundary + Case Handling

### Matching

- **Case-insensitive.** `from = "arakeet"` matches `"Arakeet"`, `"ARAKEET"`, `"arakeet"`.
- **Word-boundary-aware.** Implemented via `NSRegularExpression` with the pattern `\b<escaped-from>\b`, where `<escaped-from>` is `NSRegularExpression.escapedPattern(for:)` of the `from` string. This handles:
  - Plain words (`"Sara"` does not match `"Saratoga"`).
  - Phrases (`"oh kay are"` matches as a 3-word unit).
  - Punctuation neighbors (`"Arakeet,"` has `,` outside `\b` so `Arakeet` matches).
- **Possessives and contractions.** `"Arakeet's"` — `\b` matches between `t` and `'`, so `"Arakeet"` matches and becomes `"Parakeet's"`. Good.
- **Intra-word boundaries.** `\b` in ICU/NSRegularExpression is Unicode-aware — `"café"` will behave correctly.
- **No regex metacharacters leak in** — the user-typed `from` is always run through `escapedPattern(for:)`.

### Case preservation

Harc attempts to match the output casing to the input casing:

| Input form of match | Output form |
|---|---|
| `arakeet` (all lower) | `parakeet` (all lower) |
| `Arakeet` (Title) | `Parakeet` (Title) |
| `ARAKEET` (all upper) | `PARAKEET` (all upper) |
| `aRaKeEt` (mixed) | `Parakeet` (fall back to the `to` field literally) |

Implemented by inspecting the matched substring:

```swift
func apply(casingOf match: String, to replacement: String) -> String {
    if match == match.lowercased() { return replacement.lowercased() }
    if match == match.uppercased() { return replacement.uppercased() }
    if match.first?.isUppercase == true,
       match.dropFirst() == match.dropFirst().lowercased() {
        // "Arakeet" → Title-case the replacement
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
    return replacement  // use the `to` exactly as authored
}
```

**Multi-word phrases.** Case preservation is applied on the first word of a multi-word match only — a simplification to avoid surprising results. `"oh kay are"` (all lower) → `"okr"` (all lower); `"Oh Kay Are"` → `"Okr"`. Users who want `"OKR"` specifically should type `"OKR"` in the `to` field and accept that `"oh kay are"` at the start of a sentence will become `"OKR"` not `"Okr"` — in practice that's the right behavior.

### Order of application

Rules are applied **in user-visible order, top to bottom**. This lets the user express rule chains:

1. Run rule 1 across the full text.
2. Run rule 2 across the result.
3. …etc.

Rationale: if a user has overlapping rules (`"jeera"` → `"Jira"` and `"my jeera"` → `"my Jira board"`), they get a predictable mental model — drag the more-specific rule above the more-general one. Alternative (longest-match-wins) is smarter but harder to reason about; we prefer explicit ordering.

---

## 7. UI Sketch — Processing tab

Lives at `Sources/HarcUI/Settings/ProcessingSettingsView.swift` (new file in a new subdirectory).

```swift
import SwiftUI

public struct ProcessingSettingsView: View {
    @EnvironmentObject private var prefs: HarcPreferences
    @State private var newFrom: String = ""
    @State private var newTo: String = ""
    @State private var selection: Set<VocabularyEntry.ID> = []

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                    Text("Vocabulary")
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                    Text("Fix consistent mis-transcriptions. Applied to every new recording — case-insensitive, whole words only.")
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, HarcDesign.Space.xxs)
            }

            Section {
                // Table of entries
                Table(prefs.vocabulary.entries, selection: $selection) {
                    TableColumn("") { entry in
                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { _ in prefs.toggleEntry(id: entry.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    .width(24)

                    TableColumn("Heard") { entry in
                        TextField("", text: Binding(
                            get: { entry.from },
                            set: { prefs.updateEntry(id: entry.id, from: $0, to: nil) }
                        ))
                        .textFieldStyle(.plain)
                        .font(HarcDesign.Font.bodyMd.monospaced())
                        .foregroundStyle(Color.harcOnSurface)
                    }

                    TableColumn("Replace with") { entry in
                        TextField("", text: Binding(
                            get: { entry.to },
                            set: { prefs.updateEntry(id: entry.id, from: nil, to: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(HarcDesign.Font.bodyMd.monospaced())
                        .foregroundStyle(Color.harcOnSurface)
                    }
                }
                .frame(minHeight: 180)

                // Add row
                HStack(spacing: HarcDesign.Space.xs) {
                    TextField("Heard (e.g. Arakeet)", text: $newFrom)
                        .font(HarcDesign.Font.bodyMd)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                    TextField("Replace with (e.g. Parakeet)", text: $newTo)
                        .font(HarcDesign.Font.bodyMd)
                    Button("Add") {
                        let trimmedFrom = newFrom.trimmingCharacters(in: .whitespaces)
                        let trimmedTo = newTo.trimmingCharacters(in: .whitespaces)
                        guard !trimmedFrom.isEmpty, !trimmedTo.isEmpty else { return }
                        prefs.addEntry(from: trimmedFrom, to: trimmedTo)
                        newFrom = ""
                        newTo = ""
                    }
                    .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                        || newTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !selection.isEmpty {
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            prefs.deleteEntries(ids: selection)
                            selection.removeAll()
                        } label: {
                            Label("Delete \(selection.count)", systemImage: "trash")
                                .foregroundStyle(Color.harcError)
                        }
                    }
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Drag rows to reorder — rules apply top to bottom. Applies to new recordings only.")
                    .font(HarcDesign.Font.bodySm)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
        }
        .formStyle(.grouped)
    }
}
```

The view slots into `SettingsView` as the content of the `Processing` tab. Tabs scaffold itself is a prerequisite — see Plan doc Task 0.

---

## 8. Error Handling

### Invalid input

- **Empty `from` or empty `to`.** UI disables Add. Rules already in the list that become empty via edit are shown with an error stroke and a tooltip; they are skipped at apply time (treated as `enabled = false`). No crash.
- **Whitespace-only.** Trimmed to empty → same as above.
- **Regex metacharacters.** Not rejected — we run `escapedPattern(for:)` so `.` is literal. A `from` like `"C++"` works as expected.
- **Identical `from` == `to` (case-insensitive).** UI shows a "no effect" warning but allows save. Applied as a no-op at runtime.

### Conflicts

- **Duplicate `from` (case-insensitive).** Allowed but warned in the UI. Rules are applied in order, so the second rule operates on the output of the first — which may be exactly what the user wants. Example: `"sara" → "Sarah"`, then `"Sarah" → "Sarah Kim"`.
- **Cyclical rules** (`"a" → "b"`, `"b" → "a"`). Each rule runs exactly once per application pass, so a cycle stabilizes after one iteration — no infinite loop possible. Documented in UI footer ("applied top-to-bottom, each rule once").
- **Very large vocabulary.** We cap enabled rules at 500 to keep regex compilation bounded. Beyond 500, rules 501+ are shown disabled with an "overflow" label. This ceiling is high enough nobody realistically hits it and low enough we can't blow out the regex engine.

### Apply-time failures

`VocabularyReplacer.apply(to:)` is non-throwing. If an individual rule fails to compile (vanishingly unlikely after `escapedPattern(for:)`), it's logged to stderr and skipped; other rules still apply. The raw uncorrected text is preserved and returned on the fatally-bad-input case.

### Order of application

Described in §6. Top-to-bottom, each rule once per pass.

---

## 9. Testing

### Unit tests — `VocabularyReplacerTests` (new, `HarcClientTests`)

Add these to test the core replacement function in isolation:

- `replacesWholeWordCaseInsensitive` — `"Arakeet"` → `"Parakeet"` fires for `"Arakeet"`, `"arakeet"`, `"ARAKEET"`.
- `doesNotMatchSubword` — `"Sara"` → `"Sarah"` does NOT fire on `"Saratoga"`.
- `preservesSurroundingPunctuation` — `"Arakeet's tests"` → `"Parakeet's tests"`.
- `preservesCaseOnAllCaps` — `"ARAKEET is down"` → `"PARAKEET is down"`.
- `preservesCaseOnTitle` — `"Arakeet is down"` → `"Parakeet is down"`.
- `allLowerStaysLower` — `"arakeet is down"` → `"parakeet is down"`.
- `multiWordPhrase` — `"oh kay are"` → `"OKR"` across a 3-word phrase.
- `multiWordPhraseWithPunctuation` — `"the oh kay are, then"` works.
- `chainedRulesApplyInOrder` — rule 1 `"sara"` → `"Sarah"`, rule 2 `"Sarah"` → `"Sarah Kim"` turns `"sara"` into `"Sarah Kim"`.
- `disabledRuleIsSkipped` — disabled entries don't fire.
- `emptyVocabularyIsIdentity` — `Vocabulary.empty` returns input unchanged.
- `emptyFromOrToSkipped` — malformed entries are skipped without throw.
- `idempotent` — applying twice == applying once.
- `handlesUnicode` — `"café"` boundaries behave.
- `regexMetaInFromIsLiteral` — `from = "C++"` matches `"C++"` and not `"Cxx"`.

### Integration tests — `ChunkedTranscriberTests`

Add one test:

- `chunksAreRewrittenViaVocabulary` — stub client returns `"Arakeet is fine"` for a chunk, `ChunkedTranscriber` constructed with a vocabulary `[Arakeet → Parakeet]` produces a `SessionTranscript.joinedText` containing `"Parakeet"`.

### Integration point — HarcApp

`AppDelegate.startRecording` reads `prefs.vocabulary` and constructs `ChunkedTranscriber(vocabulary:)`. No test — covered by manual QA on a real recording.

### Manual QA checklist

1. Add `Arakeet → Parakeet`. Record a short clip saying "arakeet". Verify `.txt` says "Parakeet".
2. Add `oh kay are → OKR`. Record saying that phrase. Verify.
3. Record with an empty vocabulary → behaves identically to pre-change builds.
4. Edit vocabulary mid-recording. Verify the in-flight recording uses the pre-edit list; the next recording uses the post-edit list.
5. Add 50 entries, confirm no UI hitch on save.

---

## 10. Future Work

- **Retroactive rewrite.** "Apply to library" button that iterates `RecordingStore`, reads each `.txt`, re-runs the vocabulary pass, re-writes the `.txt` + `.json` and updates `Recording.transcriptText`. Out of v1 because it's destructive.
- **Phonetic matching.** Metaphone / Soundex at rule-authoring time ("also fire on words that sound like Arakeet"). Opt-in per rule.
- **Per-project / per-person vocabularies.** Graduate storage to SQLite, tag rules by project.
- **Import/export.** JSON file import; useful for sharing team jargon lists.
- **Inline tests in Settings.** A "Try it" text box in the Processing tab that shows live what the current vocabulary does to pasted text. Low cost, high aha.
- **Word-level timing patch.** If we ever need word timings to survive rewriting, stitch back `words[]` ranges using the new-vs-old offset per match. Real work; defer until there's a use case.
