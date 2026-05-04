# Speakers Library — Design Spec

**Date:** 2026-05-03
**Status:** Approved (brainstorming complete; awaiting plan)
**Owner:** J
**Branch:** TBD (likely `feat/speakers-library-2026-05-03`, off the merged main once PR #36 lands)

## 1. Problem

Speaker re-identification across recordings has the data infrastructure in place — `speaker_embeddings` table, `SpeakerReIDService.suggestMatches`, the v9 migration that switched to WeSpeaker v2 256-dim embeddings — but no user surface. Today the only way to label a speaker is to type a name into the Inspector for one recording, and that name doesn't propagate. Users who attend the same standup every week see "Speaker 1 / Speaker 2 / Speaker 3" in every transcript, with no concept of "Sarah" as an entity that exists across meetings.

Beyond naming, there's no UI to manage voice prints — no way to see which speakers a recording's embedder thought were the same person, no way to merge two People accidentally created as separate, no way to split one Person whose embeddings actually represent two voices, no per-Person matching threshold for the user with two siblings the embedder keeps conflating.

This design adds a full **Speakers Library** as a top-level surface in the main library window: People as first-class entities, suggest-and-confirm cross-recording labeling, and power-user merge/split/threshold tools.

## 2. Goals

- A central People entity that names voices once, surfaces everywhere they appear.
- Free-text rename in the Inspector creates a Person + backfills suggestions across past recordings.
- Suggest-and-confirm flow surfaced inline in the recording's Inspector and as a per-Person batch review in the People sidebar.
- Power-user tools per Person: merge two People, split embeddings to a new Person, per-Person match threshold.
- Render-time label resolution (database-only overlay) — never re-write the `.txt`/`.json` sidecars on disk.
- Survive model upgrades cleanly: past labels stay correct; suggestion matching gracefully gates per-embedder-kind.

## 3. Non-goals

- Transcript NER for name suggestions (e.g., "Hi Sarah" → suggest naming Speaker 2 Sarah). Pure embedding-driven only.
- Person photos / avatars. Initials in a hashed-color circle for v1.
- Cross-device People sync. Per Harc's local-first hard constraint.
- Voice biometric verification (using stored embeddings to authenticate someone in real-time).
- Bulk import of People from Contacts.app or LinkedIn.
- Per-Person summarization preferences ("summarize Sarah's contributions only").
- Renaming `Speaker N` labels in the static `.txt` / `.json` sidecars on disk. The Person mapping is a database overlay applied at render time so we don't re-write every recording's files.
- Undo for confirm / dismiss / merge / split in v1. Users can manually fix mistakes (re-link, re-merge, re-create); a 7-day history table is cut from v1.
- Bulk re-extraction of embeddings under a new model. Suggestions go silent for a Person until they're re-labeled under the new embedder; new embeddings cascade via rename-backfill from there.

## 4. Hard decisions made during brainstorming

| Decision | Choice |
|---|---|
| Scope | C — full voice-print management (Person entity + linked embeddings + merge/split + per-Person threshold), not just naming. |
| Where it lives in the app | A — new section in the main library window's sidebar, siblings to Recordings. |
| Cross-recording behavior on rename | C — suggest-and-confirm. Person created, past recordings get suggestion badges, user confirms each. No silent auto-apply. |
| Where suggestions surface | D — both inline in recording Inspector AND per-Person batch queue in the Person detail view. |
| Rollout shape | A — single coherent rollout, one branch / PR. |

## 5. Data model

### Schema (DB migration v10_people)

```sql
CREATE TABLE people (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    display_name TEXT NOT NULL,
    -- Per-Person threshold override; nil falls back to the global default.
    -- Stored as REAL in [0, 1].
    match_threshold REAL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX people_display_name_idx ON people(display_name COLLATE NOCASE);

-- Each row: one of a recording's diarized speakers (recording + speakerIndex)
-- is confirmed to be a Person. PRIMARY KEY enforces "one Person per
-- (recording, speakerIndex)" — a speaker can't be two different People in
-- the same recording.
CREATE TABLE person_speakers (
    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    speaker_index INTEGER NOT NULL,
    confirmed_at REAL NOT NULL,
    PRIMARY KEY (recording_id, speaker_index)
);
CREATE INDEX person_speakers_person_idx ON person_speakers(person_id);

-- Pending suggestions surfaced in Inspector + Person review queue.
CREATE TABLE pending_suggestions (
    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    speaker_index INTEGER NOT NULL,
    score REAL NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (person_id, recording_id, speaker_index)
);
CREATE INDEX pending_suggestions_recording_idx
    ON pending_suggestions(recording_id, speaker_index);

-- "Don't ask me again" record. Set when user dismisses a suggestion so we
-- don't re-create it on the next embedding refresh.
CREATE TABLE dismissed_suggestions (
    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    speaker_index INTEGER NOT NULL,
    dismissed_at REAL NOT NULL,
    PRIMARY KEY (person_id, recording_id, speaker_index)
);
```

### Existing tables — unchanged

- `recordings.speaker_names` (BLOB JSON `[Int: String]`) — stays as the per-recording label fallback.
- `speaker_embeddings` — stays. Person voice-prints are derived: `SELECT * FROM speaker_embeddings WHERE (recording_id, speaker_index) IN (SELECT recording_id, speaker_index FROM person_speakers WHERE person_id = ?)`.

### Why two tables (`people` + `person_speakers`) rather than `recordings.person_id` columns

Putting Person FKs directly on `speaker_embeddings` would conflate **what was captured** (an embedding observation) with **who that voice belongs to** (a labeling decision). Separating them means:
- Embeddings stay a pure observation, immune to user-driven re-labeling
- Splits and merges are linkage-only operations — no data loss, no embedding rewrites
- The `person_speakers` table is the canonical "labeling ledger" — easy to inspect, easy to roll back if a future Person model ships
- Embeddings can survive model changes; linkages survive too — they decouple cleanly

### New `HarcStore` types

```swift
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var displayName: String
    public var matchThreshold: Double?    // nil = use global default
    public var createdAt: Date
    public var updatedAt: Date
}

public struct PersonSpeakerLink: Sendable, Equatable {
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let confirmedAt: Date
}

public struct PendingSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { "\(personID)-\(recordingID)-\(speakerIndex)" }
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let score: Double
    public let createdAt: Date
}
```

### Render-time label resolver

A new `RecordingStore.resolvedSpeakerName(recordingID:speakerIndex:)` returns:
1. Linked Person's `display_name` if `person_speakers` row exists, else
2. The `speaker_names` JSON entry if present, else
3. `"Speaker \(speakerIndex + 1)"` as final fallback.

Replaces every existing `recording.speakerNames[i] ?? "Speaker \(i+1)"` read across `SpeakerInspectorSection`, `SummaryCardView`, `TranscriptPlainTextRenderer`, and `HarcWindowRootView.buildDisplaySegments`. Single fan-out point keeps Person-aware label resolution consistent.

## 6. UI surfaces

### Sidebar — new "People" section

Above the existing Recordings sections in `HarcWindowRootView.sidebar`, a `People` section lists everyone in `people` ordered by most-recently-seen first.

```
┌─────────────────────────────────┐
│ ▾ People                        │
│   ◉ Sarah               · 12 ⓘ │   ← initials avatar + name + suggestion count
│   ◉ David                · 4   │
│   ◉ Caitlin                    │
│   + Add person…                 │
│                                 │
│ ▾ Pinned                        │
│ ▾ Today                         │
│ ▾ This Week                     │
│   …                             │
└─────────────────────────────────┘
```

- Avatar = colored circle with initials. Color is hash-derived from `display_name` so it's stable per person.
- Trailing pill `· 12 ⓘ` appears only when that person has pending suggestions.
- "+ Add person…" inline button at the section's bottom: opens a sheet that takes a name and creates an empty Person (no embeddings yet — they get linked in the next recording).
- Selecting a Person row sets `selection = .person(id)`. Detail pane swaps from recording-detail to person-detail.

The existing `selection: String?` becomes:
```swift
enum LibrarySelection: Hashable {
    case recording(wavPath: String)
    case person(id: Int64)
}
```

### Person detail view (new `PersonDetailView`)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ◉ Sarah                                            [ Rename ] [ Delete ] │
│ ────────────────────────────────────────────────────────────────────────  │
│ 12 recordings · 4h 23m total · last seen Apr 27, 2026                    │
│                                                                          │
│ ── Suggested matches (12) ─────────────────────────────  [ Confirm all ] │
│   ▢ "Standup 04/27" Speaker 2 · 3m 14s · score 0.83  [ Confirm ] [ Skip ]│
│   ▢ "Brainstorm 04/24" Speaker 1 · 8m 02s · 0.81     [ Confirm ] [ Skip ]│
│   …                                                                       │
│                                                                          │
│ ── Recent utterances ──────────────────────────────────────────────────  │
│   "Standup 04/27" 0:14  Yeah, we shipped the migration over the weekend… │
│   "Brainstorm 04/24" 1:32  I think we should pivot to per-day pricing…   │
│   …                                                                       │
│                                                                          │
│ ── Voice prints (8) ──────────────────────────────  [ Merge ] [ Split ]  │
│   ▢ "Standup 04/27" Speaker 2 · 247 segments · 4m 12s · v2               │
│   ▢ "Sprint planning 04/22" Speaker 1 · 198 segments · 3m 04s · v2       │
│   …                                                                       │
│                                                                          │
│ ── Match threshold ────────────────────────────────────────────────────  │
│   ●─────────●──────  0.65  (default)   [ Reset to default ]              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Sections, top to bottom:

1. **Header** — initials avatar, name, Rename + Delete buttons. Rename is inline-editable. Delete confirms via alert ("Sarah will be removed. 8 voice prints unlink, 12 recordings revert to 'Speaker N' labels. The audio + embeddings are not deleted.")
2. **Aggregate stats line** — recording count, total speaking time (sum of `endMs - startMs` across linked SpeakerSegments), first-seen / last-seen.
3. **Suggested matches** — visible only when `pending_suggestions` rows exist. Per-row Confirm / Skip + a "Confirm all" header batch action.
4. **Recent utterances** — chronological list of speaker turns from linked recordings. Click a row → selects that recording and scrolls to that timestamp.
5. **Voice prints** — embeddings list with multi-select for **Merge** (move selected linkages to another Person via popup) and **Split** (detach selected to a new Person via name prompt). Each row shows the embedder kind (v2 / v3 / etc.) as a small badge.
6. **Match threshold** — slider 0.50–0.95 (default 0.65). Setting moves `match_threshold` away from `nil`; "Reset to default" sets it back to `nil`. Tooltip: "Higher threshold = fewer false matches, more missed matches."

### Inspector — speaker chip with suggestion

In `SpeakerInspectorSection`, each speaker row gains:
- An autocomplete-aware text field (auto-suggests existing People as you type).
- When `pending_suggestions` row exists for `(recording_id, speaker_index)`: a yellow chip below the name field — *"Speaker 2 may be Sarah · score 0.83"* with **Confirm** + **Dismiss** buttons.
- Confirming writes `person_speakers`, deletes `pending_suggestions`. Dismissing writes `dismissed_suggestions`, deletes `pending_suggestions`.

### Sidebar count badge wiring

Per-Person suggestion count = `SELECT COUNT(*) FROM pending_suggestions WHERE person_id = ?`. Driven by GRDB `ValueObservation` so it auto-updates on suggestion CRUD.

## 7. Suggestion engine + flows

### Trigger 1 — new recording finishes diarization

Post-stop, after embeddings persist (or on "Identify speakers" retry). For each newly-extracted embedding `e_new` from `recording_id = R, speaker_index = S` (and the active embedder kind):

```
For each Person P with linked embeddings of the active embedder kind:
  Compute best cosine similarity score s = max(cos(e_new, e_p)) for e_p in P's embeddings
  Let threshold = P.match_threshold ?? globalDefault   // 0.65
  If s >= threshold AND
     no person_speakers row exists for (R, S) AND
     no dismissed_suggestions row exists for (P, R, S):
        Insert pending_suggestions(P.id, R, S, score: s)
```

### Trigger 2 — new Person created via rename

The newly-named speaker's embedding is `e_new`. For all OTHER recordings:

```
For each (other recording R', speaker S') with an embedding e' of the same kind AND
        no existing person_speakers link AND
        no dismissed_suggestions for the new Person:
  s = cos(e_new, e')
  If s >= threshold:
        Insert pending_suggestions(newPerson.id, R', S', score: s)
```

Both passes are idempotent (PRIMARY KEY on `pending_suggestions` ensures no duplicates) and run on a background actor so the UI never blocks.

### Confirm flow

User clicks **Confirm** (Inspector chip OR Person detail row):
1. `INSERT OR REPLACE INTO person_speakers (person_id, recording_id, speaker_index, confirmed_at)` — replacing any existing link for that slot. Handles "fixing a mis-confirm."
2. `DELETE FROM pending_suggestions WHERE recording_id = ? AND speaker_index = ?` — clears all suggestions for this slot (it can't simultaneously be Sarah and a pending-David).
3. Render-time label resolver picks up the new linkage on the next read.

### Dismiss flow

1. `INSERT INTO dismissed_suggestions (person_id, recording_id, speaker_index, dismissed_at)`.
2. `DELETE FROM pending_suggestions WHERE person_id = ? AND recording_id = ? AND speaker_index = ?`.

Future suggestion-engine passes skip this exact triple. Other People can still be suggested for the same `(recording, speaker)` slot.

### Merge — combining two People

User selects multiple People → **Merge into…** → picks a target → confirms ("Move 4 voice prints from David to Sarah. David will be removed.").

```
BEGIN TRANSACTION
  -- Re-attribute linkages, suggestions, dismissals.
  -- For pending_suggestions and dismissed_suggestions, the re-attribution
  -- may collide on PRIMARY KEY (person_id, recording_id, speaker_index) if
  -- both Persons had rows for the same slot. Use INSERT OR REPLACE pattern:
  -- merge by selecting MAX(score) for suggestions; collapse dismissals.
  UPDATE person_speakers SET person_id = target WHERE person_id = source
  -- Pending suggestions: collapse + take MAX(score)
  -- Dismissed suggestions: collapse (any dismissal sticks)
  DELETE FROM people WHERE id = source
COMMIT
```

`ON DELETE CASCADE` on `person_speakers / pending_suggestions / dismissed_suggestions.person_id` doesn't fire after the UPDATEs because the FKs no longer point at the source.

### Split — extracting embeddings to a new Person

User selects rows in Voice Prints → **Split** → enters a name → confirm.

```
BEGIN TRANSACTION
  INSERT INTO people (display_name, created_at, updated_at) VALUES (?, ?, ?)
  -- For each selected (recording_id, speaker_index):
  UPDATE person_speakers
    SET person_id = newPerson.id
    WHERE recording_id = ? AND speaker_index = ?
COMMIT
```

Pending suggestions for those slots stay where they are (they reference `person_id`, which we didn't change for the suggestions — only for the confirmed link). Worst case: the new Person inherits no pending suggestions and waits for the next embedding pass.

### Renaming a Person

`UPDATE people SET display_name = ?, updated_at = ? WHERE id = ?`. Render-time resolver picks up the new name immediately everywhere.

### Person delete

Confirm via alert. `DELETE FROM people WHERE id = ?`. CASCADE removes all `person_speakers / pending_suggestions / dismissed_suggestions`. Embeddings stay. Recordings revert to `"Speaker N"` labels.

### Edge cases

- **Empty recording (no speech, no embeddings)** — produces no suggestions. Person sidebar stat shows "0:00" for that recording.
- **One Person split into two of themselves.** "Sarah work" + "Sarah home" each get separate suggestion engines + thresholds. Merge back if regretted.
- **Speaker confirmed to one Person, suggestion for a different Person arrives.** PRIMARY KEY on `person_speakers` is `(recording_id, speaker_index)` — a slot can only link to one Person. Suggestion-engine logic skips already-linked slots; only manual Confirm overrides.
- **Confirming a suggestion overwrites an existing link.** Yes — `INSERT OR REPLACE`. Treated as user fixing a mistake. Engine doesn't propose this unsolicited.
- **Person has zero embeddings (created via "+ Add person…" with no recording yet).** Suggestion engine skips it. Waits silently until a recording adds an embedding the user manually links. After that, rename-backfill runs.

### Model upgrade behavior

When the active embedder kind changes (e.g., WeSpeaker v2 → v3, like the v9 migration that switched stub → wespeaker_v2):

1. **Past linkages survive.** `person_speakers` is a label-only table — it says "Sarah was Speaker 2 in this recording." It doesn't depend on embeddings. Past recordings stay correctly labeled forever.
2. **Old embeddings stay in DB but stop participating in matching.** Suggestion engine queries the active `embedder_kind` only. Old-kind embeddings remain visible in the Person's Voice Prints section (with a kind badge like "v2") but aren't compared against new-kind embeddings.
3. **Suggestions go silent for a Person until they're re-linked under the new model.** Until Sarah has at least one new-kind embedding linked, the engine has nothing to compare new-model recordings against for her.
4. **Re-linking cascades via rename-backfill.** The first new-kind labeling triggers Trigger 2 — populating fresh suggestions across new-kind recordings. Within a few labelings, Sarah accumulates a v3 voice-print bank.
5. **Merge / split / threshold work across kinds** — they operate on linkages and Person-level fields, not on embedding vectors.
6. **No bulk re-extraction.** We don't walk every old WAV with the new model. Trade-off: a brief silent period in suggestions for previously-known speakers right after a model change. Acceptable.

If a future model change ever requires wiping old embeddings entirely (like v9 did), that's a one-line schema migration plus a brief in-app notice that "voice prints from the previous model have been cleared; re-label a few speakers and we'll catch up."

## 8. Files

### New

| Path | Responsibility |
|---|---|
| `Sources/HarcStore/Person.swift` | `Person`, `PersonSpeakerLink`, `PendingSuggestion` types. |
| `Sources/HarcStore/RecordingStore+People.swift` | Store API: `fetchPeople`, `createPerson`, `renamePerson`, `deletePerson`, `linkSpeaker`, `unlinkSpeaker`, `mergePeople`, `splitEmbeddings`, `fetchPendingSuggestions`, `confirmSuggestion`, `dismissSuggestion`, `pendingSuggestionCount(for:)`, `resolvedSpeakerName(...)`. |
| `Sources/HarcUI/SpeakerSuggestionEngine.swift` | The two-trigger suggestion logic. Public API: `suggestForRecording(_:)` and `suggestForNewPerson(_:)`. Wraps existing `SpeakerReIDService` cosine math. |
| `Sources/HarcUI/PeopleViewModel.swift` | `@MainActor ObservableObject` for the People sidebar. `@Published var people: [PersonRowItem]` (Person + suggestionCount + lastSeen). Subscribes via `ValueObservation`. |
| `Sources/HarcUI/PersonDetailView.swift` | Person detail-pane view. ~400 LoC. |
| `Sources/HarcUI/PersonDetailViewModel.swift` | Per-Person state: aggregate stats, pending suggestions, utterance fetcher, embeddings list. |
| `Sources/HarcUI/PersonAvatar.swift` | Colored-initials avatar. ~30 LoC. |
| `Sources/HarcStore/migrations/v10_people.swift` | DB migration. |
| `Tests/HarcStoreTests/PeopleStoreTests.swift` | Tests for create/rename/delete, link/unlink, merge, split, suggestion CRUD. |
| `Tests/HarcUITests/SpeakerSuggestionEngineTests.swift` | Tests for both suggestion passes with synthetic embeddings. |

### Modified

| Path | Change |
|---|---|
| `Sources/HarcStore/DatabaseMigrator+Harc.swift` | Register `v10_people` migration. |
| `Sources/HarcUI/HarcWindowRootView.swift` | Sidebar gains People section; `selection` becomes `LibrarySelection` enum; detail pane swaps to `PersonDetailView` when `case .person(...)`. |
| `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift` | Each speaker row gains autocomplete + suggestion chip with Confirm/Dismiss. |
| `Sources/HarcUI/SummaryCardView.swift`, `Sources/HarcClient/TranscriptPlainTextRenderer.swift`, `Sources/HarcUI/HarcWindowRootView.swift` (`buildDisplaySegments`) | Use `RecordingStore.resolvedSpeakerName(...)` so confirmed Person names show up everywhere. |
| `HarcApp/AppDelegate.swift` | Hook `SpeakerSuggestionEngine.suggestForRecording(...)` into the post-stop flow (right after embeddings persist). |

Total estimated new code: **~1500 LoC across 8 new files**, plus ~150 LoC of edits across 5 existing files.

## 9. Testing

**Unit tests (Swift Testing):**

- `PeopleStoreTests`:
  - Create / rename / delete propagates correctly + `updated_at` ticks
  - Linking a (recording, speaker) writes `person_speakers`; relinking the same slot replaces (per `INSERT OR REPLACE`)
  - Merge: linkages, suggestions, dismissals all re-attribute; source row deletes; unique constraints respected
  - Split: new Person created, selected linkages move; pending suggestions for the moved slots stay where they were
  - Cascade: deleting a Person removes their linkages, suggestions, dismissals
  - `resolvedSpeakerName`: Person link wins over `speaker_names` JSON wins over default `"Speaker N"`

- `SpeakerSuggestionEngineTests`:
  - `suggestForRecording` finds the highest-scoring Person above each Person's threshold
  - Skips slots already linked
  - Skips dismissed `(person, recording, speaker)` triples
  - Filters by active `embedder_kind` (synthetic mismatched-kind embeddings produce no suggestions)
  - Idempotent across re-runs (no duplicate inserts)
  - `suggestForNewPerson` runs after a rename, populates pending suggestions for matching past slots

- Migration v10 test: down-migration to v9 (per the project's migration test pattern).

**Manual integration smoke:**

- Start with no People. Record three meetings with two speakers each. In recording 1, label Speaker 2 as "Sarah." Verify pending suggestions appear in recordings 2 and 3 (Inspector chip) + in Sarah's detail view.
- Confirm one suggestion. Verify the recording's labels update everywhere (sidebar list, transcript turns, summary card, prompt-paste blob).
- Dismiss one suggestion. Verify it doesn't reappear after re-running diarize.
- Merge two People. Verify all linkages move and the source disappears.
- Split: pick two embeddings under "Sarah" and split into "Sarah work." Verify the slot relabels everywhere.
- Adjust per-Person threshold up; new recordings should produce fewer suggestions for that Person.
- Delete a Person. Recordings should revert to "Speaker N" labels; embeddings stay on disk (verify via direct DB query).

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Suggestion engine spam on first run after enabling People — every old recording fires suggestions for the first newly-named Person | Bounded by O(recordings × speakers) cosine comparisons; with 100 recordings × 2 speakers and ~256-dim vectors that's <50 ms. Acceptable. Add an LRU on suggestion-pass results if needed. |
| 2 | Rename-backfill might create thousands of suggestions for a frequently-recurring speaker (e.g., the user themselves) | Person detail view's "Suggested matches" panel paginates after 50; "Confirm all" clears the queue fast. |
| 3 | Cosine similarity with WeSpeaker v2 may not separate similar voices well at 0.65 default | Per-Person threshold override exists. Two siblings often conflated → bump that Person's threshold to 0.75. |
| 4 | `INSERT OR REPLACE` on `person_speakers` silently overwrites a confirmed link | Only triggered by user action (Confirm in UI). 7-day history table cut from v1. |
| 5 | Deleting a Person reverts labels everywhere — non-obvious that audio + transcripts are untouched | Delete confirmation alert spells out exactly what stays and what changes. |
| 6 | New `LibrarySelection` enum is a breaking change for the existing `selection: String?` pattern | Sweep refactor in one commit. The places that read selection are confined to `HarcWindowRootView`. |
| 7 | `ValueObservation` over `pending_suggestions` could fire frequently during a fresh-recording suggestion pass | Throttle / coalesce on the UI side via `.debounce` on the GRDB pipeline. |
| 8 | Schema migration v10 is large (4 tables + 4 indexes) | Standard append-only migration like the others; no data backfill. |

## 11. Things explicitly cut

- Transcript NER for name suggestions ("Hi Sarah" → propose Sarah). Pure embedding-driven only.
- Avatars / photos — initials + hashed color only.
- Voice biometric verification.
- Cross-device People sync (local-first hard constraint).
- Bulk import from Contacts.
- Per-Person summarization preferences.
- Rewriting `.txt` / `.json` sidecars on disk to bake in Person names — Person mapping is database-only overlay.
- Undo for confirm / dismiss / merge / split.
- Bulk re-extraction of embeddings on model upgrade.

## 12. Success criteria

1. `swift test` and `xcodebuild` both green.
2. New `PeopleStoreTests` and `SpeakerSuggestionEngineTests` pass.
3. After labeling a speaker as "Sarah" in one recording, past recordings with the same voice show pending suggestions within ~1s of opening.
4. Confirming a suggestion updates labels everywhere (sidebar row count, transcript turns, summary card, prompt-paste blob, exports) within the next render tick.
5. Person detail view loads aggregate stats and embeddings list within ~300 ms even for a Person with 100+ linked recordings (indexed queries; no full table scans).
6. Merge / split / delete operations are atomic — partial state never persists, even on cancel.
7. The render-time label resolver replaces all `recording.speakerNames[i]` reads in `HarcUI`, `HarcExport`, and `HarcSummarize` rendering paths.
8. Model upgrade (synthetic test: change `EmbedderKind` constant): past Person labels stay correct in old recordings; new recordings produce no suggestions for known People until a re-link happens.
