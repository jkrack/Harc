# Speakers Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a People entity layer + sidebar + detail view to Harc — naming, suggest-and-confirm, merge/split, per-Person threshold — built on the existing `speaker_embeddings` infrastructure.

**Architecture:** New DB tables (`people`, `person_speakers`, `pending_suggestions`, `dismissed_suggestions`) added in migration v10 alongside the existing `speaker_embeddings`. Embeddings stay pure observations; `person_speakers` is the labeling ledger. `RecordingStore.resolvedSpeakerName(...)` is the single fan-out point all UI rendering paths query for speaker labels. Suggestion engine wraps existing `SpeakerReIDService` cosine math.

**Tech Stack:** SwiftPM, GRDB/SQLite, SwiftUI on macOS 26, XCTest for `HarcStoreTests`, Swift Testing for `HarcUITests`. `SpeakerReIDService` (existing) for cosine similarity. `ValueObservation` for live UI updates.

**Spec:** `docs/superpowers/specs/2026-05-03-speakers-library-design.md`

**Branch:** `feat/speakers-library-2026-05-03` off `main` once PR #36 merges. (If executing on top of #36 instead, name with the suffix `-on-#36` so the merge order is obvious.)

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `Sources/HarcStore/Person.swift` | `Person`, `PersonSpeakerLink`, `PendingSuggestion` value types. |
| `Sources/HarcStore/RecordingStore+People.swift` | All `RecordingStore` methods for the new tables: `fetchPeople`, `createPerson(displayName:)`, `renamePerson(id:to:)`, `deletePerson(id:)`, `linkSpeaker(personID:recordingID:speakerIndex:)`, `unlinkSpeaker(recordingID:speakerIndex:)`, `mergePeople(sourceIDs:into:)`, `splitEmbeddings(slots:intoNewPersonNamed:)`, `fetchPendingSuggestions(personID:)`, `fetchPendingSuggestionsForRecording(_:)`, `confirmSuggestion(personID:recordingID:speakerIndex:)`, `dismissSuggestion(personID:recordingID:speakerIndex:)`, `pendingSuggestionCount(personID:)`, `resolvedSpeakerName(recording:speakerIndex:)`, `personRowItems()` for sidebar. |
| `Sources/HarcUI/SpeakerSuggestionEngine.swift` | Two-trigger logic. Public API: `suggestForRecording(recordingID:store:reIDService:embedderKind:)` and `suggestForNewPerson(personID:fromRecording:speakerIndex:store:reIDService:embedderKind:)`. |
| `Sources/HarcUI/PeopleViewModel.swift` | `@MainActor ObservableObject` driving the sidebar. `@Published var people: [PersonRowItem]`. Subscribes to GRDB `ValueObservation`. |
| `Sources/HarcUI/PersonDetailView.swift` | Detail-pane view: header, stats, suggestions, utterances, voice prints, threshold. ~400 LoC. |
| `Sources/HarcUI/PersonDetailViewModel.swift` | Owns per-Person view state. Fetches aggregate stats, pending suggestions, utterance excerpts, embeddings list. |
| `Sources/HarcUI/PersonAvatar.swift` | Colored-initials circle. ~30 LoC. |
| `Tests/HarcStoreTests/PeopleStoreTests.swift` | XCTest cases for People CRUD, link/unlink, merge, split, suggestion CRUD, label resolver. |
| `Tests/HarcUITests/SpeakerSuggestionEngineTests.swift` | Swift Testing cases for both engine triggers with synthetic embeddings. |

### Modified

| Path | Change |
|---|---|
| `Sources/HarcStore/DatabaseMigrator+Harc.swift` | Register `v10_people` migration with the four CREATE TABLE statements + indexes. |
| `Sources/HarcUI/HarcWindowRootView.swift` | `selection` becomes `LibrarySelection` enum; sidebar gains a People section above Recordings; detail pane swaps to `PersonDetailView` for `case .person(...)`. |
| `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift` | Each speaker row gains autocomplete (existing People) + suggestion chip with Confirm / Dismiss when a `pending_suggestions` row exists. |
| `Sources/HarcUI/SummaryCardView.swift` | Use `RecordingStore.resolvedSpeakerName(...)` instead of reading `recording.speakerNames[i]`. |
| `Sources/HarcClient/TranscriptPlainTextRenderer.swift` | Same — accept resolved labels via injection or callback. |
| `Sources/HarcUI/HarcWindowRootView.swift` (`buildDisplaySegments`) | Same. |
| `HarcApp/AppDelegate.swift` | Hook `SpeakerSuggestionEngine.suggestForRecording(...)` into the post-stop flow (after embeddings persist). |

### Deleted

None.

---

## Phase 0 — Branch + DB migration v10

### Task 0.1: Branch from main

**Files:** none changed.

- [ ] **Step 1: Create the branch off the latest `main`**

```bash
git checkout main
git pull
git checkout -b feat/speakers-library-2026-05-03
```

Expected: clean branch off `main`. PR #36 (the UI rebuild) must have merged first; if it hasn't, branch from `feat/native-ui-rebuild-2026-04-27` instead and rename the branch with a `-on-#36` suffix in the commit messages so the merge order is obvious to reviewers.

### Task 0.2: Migration v10 — schema for People, linkages, suggestions, dismissals

**Files:**
- Modify: `Sources/HarcStore/DatabaseMigrator+Harc.swift`

- [ ] **Step 1: Read the file to find the right insertion point**

```bash
grep -n "registerMigration" Sources/HarcStore/DatabaseMigrator+Harc.swift
```

Expected: a list of `migrator.registerMigration("vN_*")` calls. New migration goes after `v9_speaker_embeddings_wespeaker`.

- [ ] **Step 2: Append the v10 migration block**

After the closing brace of `v9_speaker_embeddings_wespeaker`'s registration, add:

```swift
        migrator.registerMigration("v10_people") { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    display_name TEXT NOT NULL,
                    match_threshold REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX people_display_name_idx ON people(display_name COLLATE NOCASE)")

            try db.execute(sql: """
                CREATE TABLE person_speakers (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    confirmed_at REAL NOT NULL,
                    PRIMARY KEY (recording_id, speaker_index)
                )
                """)
            try db.execute(sql: "CREATE INDEX person_speakers_person_idx ON person_speakers(person_id)")

            try db.execute(sql: """
                CREATE TABLE pending_suggestions (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    score REAL NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (person_id, recording_id, speaker_index)
                )
                """)
            try db.execute(sql: "CREATE INDEX pending_suggestions_recording_idx ON pending_suggestions(recording_id, speaker_index)")

            try db.execute(sql: """
                CREATE TABLE dismissed_suggestions (
                    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    speaker_index INTEGER NOT NULL,
                    dismissed_at REAL NOT NULL,
                    PRIMARY KEY (person_id, recording_id, speaker_index)
                )
                """)
        }
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: green.

- [ ] **Step 4: Run the migration test (existing `Tests/HarcStoreTests/MigrationTests.swift`)**

```bash
swift test --filter MigrationTests 2>&1 | tail -10
```

Expected: green. The pattern in the repo is to verify migrations apply cleanly to a fresh in-memory DB.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcStore/DatabaseMigrator+Harc.swift
git commit -m "$(cat <<'EOF'
feat(store): migration v10 — people + person_speakers + suggestions tables

DDL only. Application code lands in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 — Value types

### Task 1.1: `Person`, `PersonSpeakerLink`, `PendingSuggestion`

**Files:**
- Create: `Sources/HarcStore/Person.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// A named voice. Linked to one or more (recording, speakerIndex) slots
/// via `PersonSpeakerLink`. Renamed via `RecordingStore.renamePerson`.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var displayName: String
    /// Per-Person match threshold override; nil falls back to the global
    /// default in `SpeakerReIDService`.
    public var matchThreshold: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64,
        displayName: String,
        matchThreshold: Double? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.matchThreshold = matchThreshold
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// "Speaker S in recording R is Person P, confirmed at T."
/// PRIMARY KEY (recording_id, speaker_index) — a slot can only link to
/// one Person.
public struct PersonSpeakerLink: Sendable, Equatable {
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let confirmedAt: Date

    public init(personID: Int64, recordingID: Int64, speakerIndex: Int, confirmedAt: Date) {
        self.personID = personID
        self.recordingID = recordingID
        self.speakerIndex = speakerIndex
        self.confirmedAt = confirmedAt
    }
}

/// Surfaced in Inspector + Person review queue. Created by the suggestion
/// engine; cleared on Confirm or Dismiss.
public struct PendingSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { "\(personID)-\(recordingID)-\(speakerIndex)" }
    public let personID: Int64
    public let recordingID: Int64
    public let speakerIndex: Int
    public let score: Double
    public let createdAt: Date

    public init(
        personID: Int64,
        recordingID: Int64,
        speakerIndex: Int,
        score: Double,
        createdAt: Date
    ) {
        self.personID = personID
        self.recordingID = recordingID
        self.speakerIndex = speakerIndex
        self.score = score
        self.createdAt = createdAt
    }
}

/// What the People-sidebar VM reads. Person + derived fields.
public struct PersonRowItem: Sendable, Equatable, Identifiable {
    public var id: Int64 { person.id }
    public let person: Person
    public let suggestionCount: Int
    public let lastSeen: Date?

    public init(person: Person, suggestionCount: Int, lastSeen: Date?) {
        self.person = person
        self.suggestionCount = suggestionCount
        self.lastSeen = lastSeen
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -3
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcStore/Person.swift
git commit -m "$(cat <<'EOF'
feat(store): Person, PersonSpeakerLink, PendingSuggestion, PersonRowItem types

Pure value types. Store API + UI consume in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — RecordingStore+People (TDD)

### Task 2.1: Test scaffolding + `createPerson` / `fetchPeople`

**Files:**
- Create: `Tests/HarcStoreTests/PeopleStoreTests.swift`
- Create: `Sources/HarcStore/RecordingStore+People.swift`

- [ ] **Step 1: Read an existing test file to match patterns**

```bash
sed -n '1,30p' Tests/HarcStoreTests/RecordingStoreSpeakerEmbeddingsTests.swift
```

Note: this codebase uses **XCTest** for `HarcStoreTests` (NOT Swift Testing). `RecordingStore.inMemory()` is the in-memory factory. `seedRecording(in:wav:)` seeds a row.

- [ ] **Step 2: Write the failing test**

Create `Tests/HarcStoreTests/PeopleStoreTests.swift`:

```swift
import XCTest
@testable import HarcStore

final class PeopleStoreTests: XCTestCase {

    func test_createAndFetchPerson_roundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        XCTAssertGreaterThan(id, 0)

        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].displayName, "Sarah")
        XCTAssertNil(people[0].matchThreshold)
        XCTAssertEqual(people[0].id, id)
    }
}
```

- [ ] **Step 3: Run tests, verify failure (`createPerson` not defined)**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -10
```

Expected: compile failure.

- [ ] **Step 4: Implement the file**

Create `Sources/HarcStore/RecordingStore+People.swift`:

```swift
import Foundation
import GRDB

public extension RecordingStore {

    // MARK: - Create / fetch / rename / delete

    func createPerson(displayName: String, matchThreshold: Double? = nil) async throws -> Int64 {
        try await dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO people (display_name, match_threshold, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [displayName, matchThreshold, now, now]
            )
            return db.lastInsertedRowID
        }
    }

    func fetchPeople() async throws -> [Person] {
        try await dbQueue.read { db in
            try Self.fetchPeople(db: db)
        }
    }

    static func fetchPeople(db: Database) throws -> [Person] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, display_name, match_threshold, created_at, updated_at
            FROM people
            ORDER BY display_name COLLATE NOCASE
            """)
        return rows.map { row in
            Person(
                id: row["id"],
                displayName: row["display_name"],
                matchThreshold: row["match_threshold"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }
}
```

(`dbQueue` is an internal property of `RecordingStore`. If the actual property name is different, use whatever the existing extensions in `RecordingStore.swift` use — grep `dbQueue\|dbWriter\|writer` to confirm.)

- [ ] **Step 5: Run the test**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcStore/RecordingStore+People.swift Tests/HarcStoreTests/PeopleStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(store): createPerson + fetchPeople

First slice of the People CRUD API. Test framework matches existing
HarcStoreTests pattern (XCTest, not Swift Testing).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.2: `renamePerson` + `deletePerson`

**Files:**
- Modify: `Sources/HarcStore/RecordingStore+People.swift`
- Modify: `Tests/HarcStoreTests/PeopleStoreTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `PeopleStoreTests.swift`:

```swift
    func test_renamePerson_updatesNameAndTimestamp() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        let original = try await store.fetchPeople()[0]

        // Force a tick of clock progression.
        try await Task.sleep(nanoseconds: 50_000_000)

        try await store.renamePerson(id: id, to: "Sarah B.")
        let updated = try await store.fetchPeople()[0]
        XCTAssertEqual(updated.displayName, "Sarah B.")
        XCTAssertGreaterThan(updated.updatedAt, original.updatedAt)
    }

    func test_deletePerson_removesRow() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        try await store.deletePerson(id: id)
        XCTAssertEqual(try await store.fetchPeople().count, 0)
    }
```

- [ ] **Step 2: Run tests, verify failure (methods missing)**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
```

Expected: compile failure.

- [ ] **Step 3: Implement the methods**

Append to `Sources/HarcStore/RecordingStore+People.swift`:

```swift
public extension RecordingStore {
    func renamePerson(id: Int64, to newName: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE people SET display_name = ?, updated_at = ? WHERE id = ?",
                arguments: [newName, Date().timeIntervalSince1970, id]
            )
        }
    }

    func deletePerson(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM people WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
git add -A
git commit -m "feat(store): renamePerson + deletePerson

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: `linkSpeaker` + `unlinkSpeaker` + per-recording link fetch

**Files:**
- Modify: same two files.

- [ ] **Step 1: Add tests**

Append:

```swift
    func test_linkSpeaker_writesPersonSpeakersRow() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")

        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 1)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, personID)
        XCTAssertEqual(links[0].speakerIndex, 1)
    }

    func test_linkSpeaker_replacesExistingLinkInSameSlot() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")

        try await store.linkSpeaker(personID: sarah, recordingID: recID, speakerIndex: 0)
        try await store.linkSpeaker(personID: david, recordingID: recID, speakerIndex: 0)

        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, david, "second link should overwrite first")
    }

    func test_unlinkSpeaker_removesRow() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 0)

        try await store.unlinkSpeaker(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(try await store.fetchPersonSpeakerLinks(recordingID: recID).count, 0)
    }
```

- [ ] **Step 2: Verify failure**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
```

- [ ] **Step 3: Implement**

Append to `RecordingStore+People.swift`:

```swift
public extension RecordingStore {
    func linkSpeaker(personID: Int64, recordingID: Int64, speakerIndex: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [personID, recordingID, speakerIndex, Date().timeIntervalSince1970]
            )
        }
    }

    func unlinkSpeaker(recordingID: Int64, speakerIndex: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM person_speakers
                    WHERE recording_id = ? AND speaker_index = ?
                    """,
                arguments: [recordingID, speakerIndex]
            )
        }
    }

    func fetchPersonSpeakerLinks(recordingID: Int64) async throws -> [PersonSpeakerLink] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT person_id, recording_id, speaker_index, confirmed_at
                FROM person_speakers
                WHERE recording_id = ?
                """, arguments: [recordingID])
            return rows.map { row in
                PersonSpeakerLink(
                    personID: row["person_id"],
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    confirmedAt: Date(timeIntervalSince1970: row["confirmed_at"])
                )
            }
        }
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
git add -A
git commit -m "feat(store): linkSpeaker + unlinkSpeaker + fetchPersonSpeakerLinks

INSERT OR REPLACE on person_speakers means re-linking a slot overwrites
the prior link cleanly — handles 'fix a mis-confirm' from the UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: `resolvedSpeakerName`

**Files:**
- Same two.

- [ ] **Step 1: Add tests**

```swift
    func test_resolvedSpeakerName_personLinkWins() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        try await store.updateSpeakerNames(id: recID, names: [0: "Old fallback"])
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 0)

        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(name, "Sarah")
    }

    func test_resolvedSpeakerName_speakerNamesJSONFallback() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        try await store.updateSpeakerNames(id: recID, names: [0: "Free-text Bob"])

        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(name, "Free-text Bob")
    }

    func test_resolvedSpeakerName_defaultFallback() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")

        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 2)
        XCTAssertEqual(name, "Speaker 3")
    }
```

(If `updateSpeakerNames` is named differently, look at how `Recording.swift` exposes the field and use the right setter — grep for `speaker_names`.)

- [ ] **Step 2: Implement**

```swift
public extension RecordingStore {
    /// Resolution order:
    /// 1. Linked Person's display_name if a person_speakers row exists
    /// 2. The recordings.speaker_names JSON entry, if present
    /// 3. "Speaker N+1" as the final fallback
    func resolvedSpeakerName(recordingID: Int64, speakerIndex: Int) async throws -> String {
        try await dbQueue.read { db in
            // 1. Person link
            if let row = try Row.fetchOne(db, sql: """
                SELECT p.display_name
                FROM person_speakers ps
                JOIN people p ON p.id = ps.person_id
                WHERE ps.recording_id = ? AND ps.speaker_index = ?
                LIMIT 1
                """, arguments: [recordingID, speakerIndex]) {
                return row["display_name"]
            }
            // 2. JSON fallback
            if let blob = try Row.fetchOne(db, sql: "SELECT speaker_names FROM recordings WHERE id = ?", arguments: [recordingID])?["speaker_names"] as Data? {
                if let dict = try? JSONDecoder().decode([String: String].self, from: blob),
                   let name = dict[String(speakerIndex)] {
                    return name
                }
            }
            // 3. Default
            return "Speaker \(speakerIndex + 1)"
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
git add -A
git commit -m "feat(store): resolvedSpeakerName — single fan-out for label resolution

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.5: Suggestions CRUD — `insertPendingSuggestion`, `fetchPendingSuggestions*`, `confirmSuggestion`, `dismissSuggestion`, `pendingSuggestionCount`

**Files:** same two.

- [ ] **Step 1: Add tests**

```swift
    func test_insertAndFetchPendingSuggestion() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")

        try await store.insertPendingSuggestion(personID: personID, recordingID: recID, speakerIndex: 0, score: 0.82)
        let perPerson = try await store.fetchPendingSuggestions(personID: personID)
        XCTAssertEqual(perPerson.count, 1)
        XCTAssertEqual(perPerson[0].score, 0.82, accuracy: 0.001)

        let perRecording = try await store.fetchPendingSuggestionsForRecording(recID)
        XCTAssertEqual(perRecording.count, 1)
        XCTAssertEqual(perRecording[0].personID, personID)
    }

    func test_confirmSuggestion_writesLinkAndClearsAllSuggestionsForSlot() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")

        try await store.insertPendingSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: david, recordingID: recID, speakerIndex: 0, score: 0.71)

        try await store.confirmSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0)

        // Link written
        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, sarah)
        // ALL suggestions for slot cleared (David's too)
        XCTAssertEqual(try await store.fetchPendingSuggestionsForRecording(recID).count, 0)
    }

    func test_dismissSuggestion_writesDismissalAndClearsSpecificSuggestion() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")

        try await store.insertPendingSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: david, recordingID: recID, speakerIndex: 0, score: 0.71)

        try await store.dismissSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0)

        // Sarah's suggestion cleared, David's stays
        let remaining = try await store.fetchPendingSuggestionsForRecording(recID)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].personID, david)
        // Dismissed table records Sarah
        XCTAssertTrue(try await store.isDismissed(personID: sarah, recordingID: recID, speakerIndex: 0))
    }

    func test_pendingSuggestionCount() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let personID = try await store.createPerson(displayName: "Sarah")

        try await store.insertPendingSuggestion(personID: personID, recordingID: recA, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: personID, recordingID: recB, speakerIndex: 1, score: 0.79)

        let count = try await store.pendingSuggestionCount(personID: personID)
        XCTAssertEqual(count, 2)
    }
```

- [ ] **Step 2: Implement**

```swift
public extension RecordingStore {

    func insertPendingSuggestion(personID: Int64, recordingID: Int64, speakerIndex: Int, score: Double) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO pending_suggestions
                        (person_id, recording_id, speaker_index, score, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [personID, recordingID, speakerIndex, score, Date().timeIntervalSince1970]
            )
        }
    }

    func fetchPendingSuggestions(personID: Int64) async throws -> [PendingSuggestion] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT person_id, recording_id, speaker_index, score, created_at
                FROM pending_suggestions
                WHERE person_id = ?
                ORDER BY score DESC
                """, arguments: [personID])
            return rows.map(Self.suggestion(from:))
        }
    }

    func fetchPendingSuggestionsForRecording(_ recordingID: Int64) async throws -> [PendingSuggestion] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT person_id, recording_id, speaker_index, score, created_at
                FROM pending_suggestions
                WHERE recording_id = ?
                ORDER BY score DESC
                """, arguments: [recordingID])
            return rows.map(Self.suggestion(from:))
        }
    }

    func confirmSuggestion(personID: Int64, recordingID: Int64, speakerIndex: Int) async throws {
        try await dbQueue.write { db in
            // Write the link (replacing any prior link for this slot).
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO person_speakers
                        (person_id, recording_id, speaker_index, confirmed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [personID, recordingID, speakerIndex, Date().timeIntervalSince1970]
            )
            // Clear ALL suggestions for this slot — once confirmed, no other
            // pending-Person can also be the answer.
            try db.execute(
                sql: """
                    DELETE FROM pending_suggestions
                    WHERE recording_id = ? AND speaker_index = ?
                    """,
                arguments: [recordingID, speakerIndex]
            )
        }
    }

    func dismissSuggestion(personID: Int64, recordingID: Int64, speakerIndex: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO dismissed_suggestions
                        (person_id, recording_id, speaker_index, dismissed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [personID, recordingID, speakerIndex, Date().timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    DELETE FROM pending_suggestions
                    WHERE person_id = ? AND recording_id = ? AND speaker_index = ?
                    """,
                arguments: [personID, recordingID, speakerIndex]
            )
        }
    }

    func isDismissed(personID: Int64, recordingID: Int64, speakerIndex: Int) async throws -> Bool {
        try await dbQueue.read { db in
            let n = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM dismissed_suggestions
                WHERE person_id = ? AND recording_id = ? AND speaker_index = ?
                """, arguments: [personID, recordingID, speakerIndex]) ?? 0
            return n > 0
        }
    }

    func pendingSuggestionCount(personID: Int64) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_suggestions WHERE person_id = ?", arguments: [personID]) ?? 0
        }
    }

    fileprivate static func suggestion(from row: Row) -> PendingSuggestion {
        PendingSuggestion(
            personID: row["person_id"],
            recordingID: row["recording_id"],
            speakerIndex: row["speaker_index"],
            score: row["score"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
git add -A
git commit -m "feat(store): suggestion CRUD — insert / fetch / confirm / dismiss / count

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.6: `mergePeople` + `splitEmbeddings`

**Files:** same two.

- [ ] **Step 1: Add tests**

```swift
    func test_mergePeople_movesLinksAndSuggestionsAndDeletesSource() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let sarahB = try await store.createPerson(displayName: "Sarah B")

        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: sarahB, recordingID: recB, speakerIndex: 1)
        try await store.insertPendingSuggestion(personID: sarahB, recordingID: recA, speakerIndex: 1, score: 0.7)

        try await store.mergePeople(sourceIDs: [sarahB], into: sarah)

        // Source person gone
        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].id, sarah)
        // Linkages re-attributed
        let linksB = try await store.fetchPersonSpeakerLinks(recordingID: recB)
        XCTAssertEqual(linksB.count, 1)
        XCTAssertEqual(linksB[0].personID, sarah)
        // Suggestions re-attributed
        let suggestions = try await store.fetchPendingSuggestions(personID: sarah)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].recordingID, recA)
    }

    func test_splitEmbeddings_movesSelectedSlotsToNewPerson() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: sarah, recordingID: recB, speakerIndex: 0)

        let newID = try await store.splitEmbeddings(
            slots: [(recordingID: recB, speakerIndex: 0)],
            intoNewPersonNamed: "Sarah work"
        )

        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 2)
        XCTAssertTrue(people.contains { $0.id == newID && $0.displayName == "Sarah work" })

        // recA still linked to Sarah
        XCTAssertEqual(try await store.fetchPersonSpeakerLinks(recordingID: recA)[0].personID, sarah)
        // recB now linked to the new Person
        XCTAssertEqual(try await store.fetchPersonSpeakerLinks(recordingID: recB)[0].personID, newID)
    }
```

- [ ] **Step 2: Implement**

```swift
public extension RecordingStore {

    /// Move all linkages, suggestions, and dismissals from `sourceIDs` to
    /// `targetID`, then delete the source People rows. PRIMARY KEY collisions
    /// on `pending_suggestions` and `dismissed_suggestions` are handled by
    /// re-inserting the highest score / earliest dismissal and deleting source.
    func mergePeople(sourceIDs: [Int64], into targetID: Int64) async throws {
        guard !sourceIDs.isEmpty else { return }
        try await dbQueue.write { db in
            for sourceID in sourceIDs where sourceID != targetID {
                // Re-attribute confirmed linkages.
                try db.execute(
                    sql: "UPDATE person_speakers SET person_id = ? WHERE person_id = ?",
                    arguments: [targetID, sourceID]
                )
                // Re-attribute pending suggestions, collapsing any (target,
                // recording, speaker) collision by taking MAX(score).
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO pending_suggestions
                            (person_id, recording_id, speaker_index, score, created_at)
                        SELECT ?, recording_id, speaker_index,
                               MAX(score),
                               MIN(created_at)
                        FROM (
                            SELECT recording_id, speaker_index, score, created_at
                            FROM pending_suggestions WHERE person_id = ?
                            UNION ALL
                            SELECT recording_id, speaker_index, score, created_at
                            FROM pending_suggestions WHERE person_id = ?
                        )
                        GROUP BY recording_id, speaker_index
                        """,
                    arguments: [targetID, sourceID, targetID]
                )
                try db.execute(
                    sql: "DELETE FROM pending_suggestions WHERE person_id = ?",
                    arguments: [sourceID]
                )
                // Re-attribute dismissals (any dismissal sticks).
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO dismissed_suggestions
                            (person_id, recording_id, speaker_index, dismissed_at)
                        SELECT ?, recording_id, speaker_index, MIN(dismissed_at)
                        FROM (
                            SELECT recording_id, speaker_index, dismissed_at
                            FROM dismissed_suggestions WHERE person_id = ?
                            UNION ALL
                            SELECT recording_id, speaker_index, dismissed_at
                            FROM dismissed_suggestions WHERE person_id = ?
                        )
                        GROUP BY recording_id, speaker_index
                        """,
                    arguments: [targetID, sourceID, targetID]
                )
                try db.execute(
                    sql: "DELETE FROM dismissed_suggestions WHERE person_id = ?",
                    arguments: [sourceID]
                )
                // Finally drop the source person row.
                try db.execute(
                    sql: "DELETE FROM people WHERE id = ?",
                    arguments: [sourceID]
                )
            }
        }
    }

    /// Move the selected (recording, speaker) linkages off their current
    /// Persons and onto a brand-new Person with the given name. Returns
    /// the new Person ID.
    func splitEmbeddings(slots: [(recordingID: Int64, speakerIndex: Int)], intoNewPersonNamed name: String) async throws -> Int64 {
        try await dbQueue.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO people (display_name, match_threshold, created_at, updated_at)
                    VALUES (?, NULL, ?, ?)
                    """,
                arguments: [name, now, now]
            )
            let newID = db.lastInsertedRowID
            for slot in slots {
                try db.execute(
                    sql: """
                        UPDATE person_speakers
                        SET person_id = ?, confirmed_at = ?
                        WHERE recording_id = ? AND speaker_index = ?
                        """,
                    arguments: [newID, now, slot.recordingID, slot.speakerIndex]
                )
            }
            return newID
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter PeopleStoreTests 2>&1 | tail -5
git add -A
git commit -m "feat(store): mergePeople + splitEmbeddings

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.7: `personRowItems` (sidebar feed)

**Files:** same two.

- [ ] **Step 1: Add test**

```swift
    func test_personRowItems_includesSuggestionCountAndLastSeen() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recA, speakerIndex: 0)
        try await store.insertPendingSuggestion(personID: personID, recordingID: recA, speakerIndex: 1, score: 0.8)

        let items = try await store.personRowItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].person.displayName, "Sarah")
        XCTAssertEqual(items[0].suggestionCount, 1)
        XCTAssertNotNil(items[0].lastSeen)
    }
```

- [ ] **Step 2: Implement**

```swift
public extension RecordingStore {
    func personRowItems() async throws -> [PersonRowItem] {
        try await dbQueue.read { db in
            let people = try Self.fetchPeople(db: db)
            return try people.map { person in
                let count = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM pending_suggestions WHERE person_id = ?",
                    arguments: [person.id]) ?? 0
                let lastSeenTS = try Double.fetchOne(db, sql: """
                    SELECT MAX(r.started_at)
                    FROM person_speakers ps
                    JOIN recordings r ON r.id = ps.recording_id
                    WHERE ps.person_id = ?
                    """, arguments: [person.id])
                let lastSeen = lastSeenTS.map { Date(timeIntervalSince1970: $0) }
                return PersonRowItem(person: person, suggestionCount: count, lastSeen: lastSeen)
            }
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test 2>&1 | tail -3
git add -A
git commit -m "feat(store): personRowItems for the People sidebar feed

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Label-resolver fan-out

### Task 3.1: Replace `recording.speakerNames[i]` reads at the four sites

**Files:**
- Modify: `Sources/HarcUI/SummaryCardView.swift`
- Modify: `Sources/HarcClient/TranscriptPlainTextRenderer.swift`
- Modify: `Sources/HarcUI/HarcWindowRootView.swift` (`buildDisplaySegments`)
- Modify: `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift` (only its display path; the rename input is Phase 8)

- [ ] **Step 1: Find every read site**

```bash
grep -rn "speakerNames\[" Sources/ | grep -v Tests
```

For each site, determine: do we have access to the `RecordingStore` here? If yes, switch to `await store.resolvedSpeakerName(...)`. If the call site is sync (e.g., `TranscriptPlainTextRenderer.render` is pure), pass in a pre-resolved label dictionary instead.

- [ ] **Step 2: Update `TranscriptPlainTextRenderer` to take a resolved-label callback**

The renderer is pure today. Add a `nameFor: (Int) -> String` parameter (default uses the existing `recording.speakerNames[$0]` fallback so existing call sites keep working). Callers that have a store call `await store.resolvedSpeakerName(...)` for each speaker index ahead of render and pass a closure that looks up the pre-resolved map.

- [ ] **Step 3: Update `HarcWindowRootView.buildDisplaySegments`**

It's called from a SwiftUI view body — sync. Walk the speaker indices ahead-of-time in a `.task` and cache `[Int: String]`; pass that into `buildDisplaySegments`.

- [ ] **Step 4: Update `SummaryCardView`**

It already takes a `RecordingStore`. Swap `recording.speakerNames[i] ?? "Speaker \(i+1)"` for `await store.resolvedSpeakerName(...)`, called once per speaker on view load and cached in a `@State`.

- [ ] **Step 5: Update `SpeakerInspectorSection` display path**

Same — pre-resolve names via the store on view load.

- [ ] **Step 6: Build + run all tests**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -3
```

Expected: green, no behavior change for recordings without People links (resolver falls back to `speaker_names` JSON).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(ui): all label reads go through RecordingStore.resolvedSpeakerName

Single fan-out point for speaker label resolution. Prepares the codebase
for Person-aware labeling without changing any rendered output for
recordings that don't yet have People linked.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — `SpeakerSuggestionEngine` (TDD)

### Task 4.1: Engine skeleton + new-recording trigger

**Files:**
- Create: `Sources/HarcUI/SpeakerSuggestionEngine.swift`
- Create: `Tests/HarcUITests/SpeakerSuggestionEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import HarcStore
@testable import HarcUI

@Suite("SpeakerSuggestionEngine")
@MainActor
struct SpeakerSuggestionEngineTests {

    @Test("suggestForRecording inserts pending row when embedding matches a Person above threshold")
    func suggestsAboveThreshold() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        // Seed Sarah's embedding under recA + a near-duplicate embedding under recB.
        let sarahVec: [Float] = (0..<256).map { _ in Float.random(in: -0.3...0.3) }
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recA, speakerIndex: 0,
                embedding: EmbeddingBlob.encode(sarahVec),
                segmentCount: 4, totalMs: 6000,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            RecordingStore.SpeakerEmbeddingRow(
                recordingID: recB, speakerIndex: 0,
                embedding: EmbeddingBlob.encode(sarahVec),  // identical = cosine 1.0
                segmentCount: 3, totalMs: 4500,
                embedderKind: EmbedderKind.wespeakerV2
            )
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)

        let suggestions = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].personID == sarah)
        #expect(suggestions[0].score >= 0.99)
    }
}
```

(Note: this test uses `PeopleStoreTests.seedRecording` — that helper needs to be `internal` or replicated. If `seedRecording` is `private`, factor it out into a shared test helper file or duplicate the body inline.)

- [ ] **Step 2: Verify failure**

```bash
swift test --filter SpeakerSuggestionEngineTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement the engine**

```swift
import Foundation
import HarcStore
import HarcVoiceprint

/// Two-trigger speaker-identity suggestion engine. Reads embeddings from
/// `RecordingStore.speaker_embeddings`, compares via cosine similarity,
/// writes pending suggestions to `pending_suggestions` for matches above
/// each Person's threshold. Idempotent (PRIMARY KEY on
/// pending_suggestions prevents duplicates) and runs off the main actor.
public actor SpeakerSuggestionEngine {
    private let store: RecordingStore
    private let embedderKind: EmbedderKind
    private let globalDefaultThreshold: Double

    public init(store: RecordingStore, embedderKind: EmbedderKind, globalDefaultThreshold: Double = 0.65) {
        self.store = store
        self.embedderKind = embedderKind
        self.globalDefaultThreshold = globalDefaultThreshold
    }

    /// Trigger 1: a recording just finished diarization. For each newly-
    /// extracted embedding, find the highest-scoring Person and (if above
    /// threshold and the slot isn't linked or dismissed) write a
    /// `pending_suggestions` row.
    public func suggestForRecording(recordingID: Int64) async throws {
        let newEmbeddings = try await store.fetchSpeakerEmbeddings(recordingID: recordingID, embedderKind: embedderKind)
        guard !newEmbeddings.isEmpty else { return }

        let people = try await store.fetchPeople()
        guard !people.isEmpty else { return }

        for emb in newEmbeddings {
            // Skip slots already linked.
            let linksForRec = try await store.fetchPersonSpeakerLinks(recordingID: recordingID)
            if linksForRec.contains(where: { $0.speakerIndex == emb.speakerIndex }) { continue }

            // Find best matching Person.
            let newVec = EmbeddingBlob.decode(emb.embedding)
            var bestPerson: Person?
            var bestScore: Double = 0
            for person in people {
                let personEmbeddings = try await store.fetchEmbeddingsForPerson(person.id, embedderKind: embedderKind)
                for pe in personEmbeddings {
                    let v = EmbeddingBlob.decode(pe.embedding)
                    let s = cosine(newVec, v)
                    if s > bestScore {
                        bestScore = s
                        bestPerson = person
                    }
                }
            }
            guard let person = bestPerson else { continue }
            let threshold = person.matchThreshold ?? globalDefaultThreshold
            guard bestScore >= threshold else { continue }

            // Skip if dismissed.
            if try await store.isDismissed(personID: person.id, recordingID: recordingID, speakerIndex: emb.speakerIndex) {
                continue
            }

            try await store.insertPendingSuggestion(
                personID: person.id,
                recordingID: recordingID,
                speakerIndex: emb.speakerIndex,
                score: bestScore
            )
        }
    }

    /// Trigger 2: a new Person was just created via rename. Walk all OTHER
    /// recordings' embeddings; if any match the new Person's seed embedding
    /// above threshold and aren't already linked or dismissed, suggest.
    public func suggestForNewPerson(personID: Int64, fromRecording recordingID: Int64, speakerIndex: Int) async throws {
        let seedRow = try await store.speakerEmbedding(recordingID: recordingID, speakerIndex: speakerIndex)
        guard let seed = seedRow, seed.embedderKind == embedderKind else { return }
        let seedVec = EmbeddingBlob.decode(seed.embedding)

        let person = try await store.fetchPeople().first(where: { $0.id == personID })
        let threshold = person?.matchThreshold ?? globalDefaultThreshold

        let allEmbeddings = try await store.fetchAllSpeakerEmbeddings(embedderKind: embedderKind)
        for cand in allEmbeddings {
            // Skip the seed itself.
            if cand.recordingID == recordingID && cand.speakerIndex == speakerIndex { continue }

            // Skip already-linked slots.
            let linkedFor = try await store.fetchPersonSpeakerLinks(recordingID: cand.recordingID)
            if linkedFor.contains(where: { $0.speakerIndex == cand.speakerIndex }) { continue }

            if try await store.isDismissed(personID: personID, recordingID: cand.recordingID, speakerIndex: cand.speakerIndex) {
                continue
            }

            let s = cosine(seedVec, EmbeddingBlob.decode(cand.embedding))
            if s >= threshold {
                try await store.insertPendingSuggestion(
                    personID: personID,
                    recordingID: cand.recordingID,
                    speakerIndex: cand.speakerIndex,
                    score: s
                )
            }
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let av = Double(a[i]); let bv = Double(b[i])
            dot += av * bv
            na += av * av
            nb += bv * bv
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
```

- [ ] **Step 4: Add the missing store helpers `fetchSpeakerEmbeddings(recordingID:embedderKind:)`, `fetchEmbeddingsForPerson(_:embedderKind:)`, `fetchAllSpeakerEmbeddings(embedderKind:)` to `RecordingStore+People.swift`**

```swift
public extension RecordingStore {
    func fetchSpeakerEmbeddings(recordingID: Int64, embedderKind: EmbedderKind) async throws -> [SpeakerEmbeddingRow] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                WHERE recording_id = ? AND embedder_kind = ?
                """, arguments: [recordingID, embedderKind.rawValue])
            return rows.map(SpeakerEmbeddingRow.init(row:))
        }
    }

    func fetchEmbeddingsForPerson(_ personID: Int64, embedderKind: EmbedderKind) async throws -> [SpeakerEmbeddingRow] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.recording_id, e.speaker_index, e.embedding, e.segment_count, e.total_ms, e.embedder_kind
                FROM speaker_embeddings e
                JOIN person_speakers ps
                  ON ps.recording_id = e.recording_id
                 AND ps.speaker_index = e.speaker_index
                WHERE ps.person_id = ? AND e.embedder_kind = ?
                """, arguments: [personID, embedderKind.rawValue])
            return rows.map(SpeakerEmbeddingRow.init(row:))
        }
    }

    func fetchAllSpeakerEmbeddings(embedderKind: EmbedderKind) async throws -> [SpeakerEmbeddingRow] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                WHERE embedder_kind = ?
                """, arguments: [embedderKind.rawValue])
            return rows.map(SpeakerEmbeddingRow.init(row:))
        }
    }
}
```

(`SpeakerEmbeddingRow.init(row:)` may need a small initializer extension if it doesn't already exist. Look at `Sources/HarcStore/RecordingStore.swift` around line 381 for the existing pattern.)

- [ ] **Step 5: Run the test**

```bash
swift test --filter SpeakerSuggestionEngineTests 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcUI/SpeakerSuggestionEngine.swift Sources/HarcStore/RecordingStore+People.swift Tests/HarcUITests/SpeakerSuggestionEngineTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): SpeakerSuggestionEngine — Trigger 1 (new recording)

Walks newly-extracted embeddings, finds the best matching Person via
cosine similarity, writes pending_suggestions rows for matches above
threshold (default 0.65, per-Person override). Skips already-linked
slots and dismissed (person, recording, speaker) triples.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4.2: Trigger 2 (rename-backfill) tests + edge cases

**Files:**
- Modify: `Tests/HarcUITests/SpeakerSuggestionEngineTests.swift`

- [ ] **Step 1: Add tests**

```swift
    @Test("suggestForRecording skips slots already linked")
    func skipsLinkedSlots() async throws {
        // Same setup as suggestsAboveThreshold but pre-link Speaker 0 in recB
        // to a different Person; verify no suggestion gets written.
        let store = try await RecordingStore.inMemory()
        let recA = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: david, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: -0.3...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForRecording skips dismissed (person, recording, speaker) triples")
    func skipsDismissed() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.dismissSuggestion(personID: sarah, recordingID: recB, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: -0.3...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        #expect(try await store.fetchPendingSuggestionsForRecording(recB).isEmpty)
    }

    @Test("suggestForNewPerson backfills suggestions across older recordings")
    func newPersonBackfill() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/b.wav")
        let v: [Float] = (0..<256).map { _ in Float.random(in: -0.3...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 1, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        // Person + link the seed slot.
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
        try await engine.suggestForNewPerson(personID: sarah, fromRecording: recA, speakerIndex: 0)

        // Should have suggested Sarah for recB Speaker 1.
        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
        #expect(s[0].personID == sarah)
        #expect(s[0].speakerIndex == 1)
    }

    @Test("idempotent — calling suggestForRecording twice doesn't duplicate")
    func idempotent() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await PeopleStoreTests.seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        let v: [Float] = (0..<256).map { _ in Float.random(in: -0.3...0.3) }
        let blob = EmbeddingBlob.encode(v)
        try await store.upsertSpeakerEmbeddings(recordingID: recA, rows: [
            .init(recordingID: recA, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])
        try await store.upsertSpeakerEmbeddings(recordingID: recB, rows: [
            .init(recordingID: recB, speakerIndex: 0, embedding: blob, segmentCount: 1, totalMs: 1000, embedderKind: EmbedderKind.wespeakerV2)
        ])

        let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
        try await engine.suggestForRecording(recordingID: recB)
        try await engine.suggestForRecording(recordingID: recB)

        let s = try await store.fetchPendingSuggestionsForRecording(recB)
        #expect(s.count == 1)
    }
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter SpeakerSuggestionEngineTests 2>&1 | tail -5
git add -A
git commit -m "test(ui): SpeakerSuggestionEngine edge cases — link skip, dismiss skip, backfill, idempotent

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — `LibrarySelection` enum + sidebar People section

### Task 5.1: Refactor `selection: String?` → `LibrarySelection` enum

**Files:**
- Modify: `Sources/HarcUI/HarcWindowRootView.swift`

- [ ] **Step 1: Find all uses of `selection`**

```bash
grep -n "selection" Sources/HarcUI/HarcWindowRootView.swift | head -30
```

- [ ] **Step 2: Add the enum at file scope**

```swift
enum LibrarySelection: Hashable {
    case recording(wavPath: String)
    case person(id: Int64)
}
```

- [ ] **Step 3: Replace `@State private var selection: String?` with `@State private var selection: LibrarySelection?`**

- [ ] **Step 4: Update every read site**

Anywhere that did `selection == nil` becomes `selection == nil`. Anywhere that read `selection` as a wavPath becomes:

```swift
if case .recording(let wavPath) = selection { ... }
```

The recording row's `.tag(rec.wavPath)` becomes `.tag(LibrarySelection.recording(wavPath: rec.wavPath))`.

The `selectedRecording` computed property becomes:
```swift
private var selectedRecording: Recording? {
    guard case .recording(let wavPath) = selection else { return nil }
    if let hit = libraryVM.hits.first(where: { $0.recording.wavPath == wavPath }) {
        return hit.recording
    }
    return libraryVM.recordings.first { $0.wavPath == wavPath }
}
```

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | tail -10
```

Iterate until clean.

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -3
```

Expected: green. No behavior change yet (People case unused).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(library): selection becomes LibrarySelection enum

No behavior change. Sets up the People sidebar to share the selection
mechanism with Recordings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.2: `PersonAvatar` view

**Files:**
- Create: `Sources/HarcUI/PersonAvatar.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Colored circle with the Person's initials. Color is hash-derived from
/// the display name so it's stable per Person without storing anything.
public struct PersonAvatar: View {
    let displayName: String
    var size: CGFloat = 22

    public init(displayName: String, size: CGFloat = 22) {
        self.displayName = displayName
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Text(initials)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    /// Hash-derived hue. SHA-stable across launches.
    private var color: Color {
        let hash = abs(displayName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.7)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -3
git add Sources/HarcUI/PersonAvatar.swift
git commit -m "feat(ui): PersonAvatar — initials in a hashed-color circle

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.3: `PeopleViewModel`

**Files:**
- Create: `Sources/HarcUI/PeopleViewModel.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import SwiftUI
import Combine
import GRDB
import HarcStore

@MainActor
public final class PeopleViewModel: ObservableObject {
    @Published public private(set) var people: [PersonRowItem] = []

    private let store: RecordingStore
    private var cancellable: AnyCancellable?

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        guard cancellable == nil else { return }
        // Re-read PersonRowItems whenever any of the four People tables change.
        let observation = ValueObservation.tracking { db in
            // Track row counts on the four tables — cheap and fires whenever
            // any of the underlying state could change a sidebar row.
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people") ?? 0
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person_speakers") ?? 0
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_suggestions") ?? 0
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dismissed_suggestions") ?? 0
        }
        cancellable = observation
            .publisher(in: store.dbReader)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] _ in
                    Task { [weak self] in
                        guard let self else { return }
                        let items = (try? await self.store.personRowItems()) ?? []
                        await MainActor.run { self.people = items }
                    }
                }
            )
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
```

(The `store.dbReader` accessor may be named differently — check `RecordingStore.swift` for the public getter that exposes the `DatabaseReader` for `ValueObservation`. If it's not exposed, expose it as a `public var dbReader: any DatabaseReader { dbQueue }` in a small extension.)

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -3
git add -A
git commit -m "feat(ui): PeopleViewModel — sidebar feed via GRDB ValueObservation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.4: People section in the sidebar

**Files:**
- Modify: `Sources/HarcUI/HarcWindowRootView.swift`
- Modify: `HarcApp/WindowControllers/HarcWindowController.swift` (instantiate `PeopleViewModel` and pass in)

- [ ] **Step 1: Add `peopleVM` to `HarcWindowRootView` init**

```swift
@ObservedObject var peopleVM: PeopleViewModel
```

Update the init signature + the controller's construction site.

- [ ] **Step 2: Add the People section to the sidebar `groupedList`**

At the top of `groupedList`'s `List(selection:)` body, insert:

```swift
Section("People") {
    ForEach(peopleVM.people) { item in
        HStack(spacing: 8) {
            PersonAvatar(displayName: item.person.displayName, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.person.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let lastSeen = item.lastSeen {
                    Text(Self.relativeDate(lastSeen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if item.suggestionCount > 0 {
                Text("\(item.suggestionCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow.opacity(0.25)))
                    .foregroundStyle(.primary)
            }
        }
        .tag(LibrarySelection.person(id: item.person.id))
    }
    Button {
        // Inline add: open a small sheet
        showingAddPerson = true
    } label: {
        Label("Add person…", systemImage: "person.crop.circle.badge.plus")
            .font(.subheadline)
    }
    .buttonStyle(.plain)
}
```

Add `@State private var showingAddPerson = false` and the sheet at the body level:

```swift
.sheet(isPresented: $showingAddPerson) {
    AddPersonSheet { name in
        Task {
            _ = try? await store.createPerson(displayName: name)
        }
    }
}
```

`AddPersonSheet`: a 30-line view with a `TextField`, Cancel + Add buttons.

- [ ] **Step 3: Add `relativeDate(_:)` helper**

Use `RelativeDateTimeFormatter` for "2 days ago" / "Apr 24" formatting.

- [ ] **Step 4: Wire `peopleVM.start()` / `peopleVM.stop()` in `body.onAppear` / `onDisappear`**

- [ ] **Step 5: Build + smoke**

```bash
swift build && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(library): People section in the sidebar

Lists each Person with avatar, last-seen, and a suggestion count badge.
Inline 'Add person…' opens a small sheet. Selection sets
LibrarySelection.person(id:) — detail pane handler in next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — `PersonDetailView` (basic: header + stats + utterances)

### Task 6.1: `PersonDetailViewModel` + utterance fetching

**Files:**
- Create: `Sources/HarcUI/PersonDetailViewModel.swift`

- [ ] **Step 1: Write the model**

```swift
import Foundation
import SwiftUI
import HarcStore

public struct UtteranceExcerpt: Sendable, Equatable, Identifiable {
    public var id: String { "\(recordingID)-\(speakerIndex)-\(startMs)" }
    public let recordingID: Int64
    public let recordingTitle: String
    public let speakerIndex: Int
    public let startMs: Int
    public let snippet: String
}

@MainActor
public final class PersonDetailViewModel: ObservableObject {
    @Published public private(set) var person: Person?
    @Published public private(set) var stats: PersonStats?
    @Published public private(set) var utterances: [UtteranceExcerpt] = []

    public struct PersonStats: Sendable, Equatable {
        public var recordingCount: Int
        public var totalSpeakingMs: Int
        public var firstSeen: Date?
        public var lastSeen: Date?
    }

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func load(personID: Int64) async {
        person = try? await store.fetchPeople().first(where: { $0.id == personID })
        stats = try? await store.fetchPersonStats(personID: personID)
        utterances = (try? await store.fetchUtterancesForPerson(personID: personID, limit: 50)) ?? []
    }
}
```

- [ ] **Step 2: Add the supporting store methods to `RecordingStore+People.swift`**

```swift
public extension RecordingStore {

    func fetchPersonStats(personID: Int64) async throws -> PersonDetailViewModel.PersonStats {
        try await dbQueue.read { db in
            let recCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(DISTINCT recording_id) FROM person_speakers WHERE person_id = ?",
                arguments: [personID]) ?? 0
            // Total speaking ms is sum of (endMs - startMs) across linked SpeakerSegments.
            // SpeakerSegments live in the .json sidecar, not the DB, so we approximate
            // here using totalMs from speaker_embeddings (sum across linked slots).
            let totalMs = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(e.total_ms), 0)
                FROM person_speakers ps
                JOIN speaker_embeddings e
                  ON e.recording_id = ps.recording_id AND e.speaker_index = ps.speaker_index
                WHERE ps.person_id = ?
                """, arguments: [personID]) ?? 0
            let bounds = try Row.fetchOne(db, sql: """
                SELECT MIN(r.started_at) AS first_seen, MAX(r.started_at) AS last_seen
                FROM person_speakers ps
                JOIN recordings r ON r.id = ps.recording_id
                WHERE ps.person_id = ?
                """, arguments: [personID])
            let firstSeen = (bounds?["first_seen"] as Double?).map { Date(timeIntervalSince1970: $0) }
            let lastSeen = (bounds?["last_seen"] as Double?).map { Date(timeIntervalSince1970: $0) }
            return PersonDetailViewModel.PersonStats(
                recordingCount: recCount,
                totalSpeakingMs: totalMs,
                firstSeen: firstSeen,
                lastSeen: lastSeen
            )
        }
    }

    func fetchUtterancesForPerson(personID: Int64, limit: Int) async throws -> [UtteranceExcerpt] {
        // For v1, derive from the per-recording .json sidecar at fetch time.
        // Read the recordings linked to this Person, parse their json, walk
        // SpeakerSegments to find the ones owned by the linked speakerIndex,
        // join with words for the snippet.
        let links = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ps.recording_id, ps.speaker_index, r.title, r.json_path, r.started_at, r.suggested_title
                FROM person_speakers ps
                JOIN recordings r ON r.id = ps.recording_id
                WHERE ps.person_id = ?
                ORDER BY r.started_at DESC
                LIMIT ?
                """, arguments: [personID, limit])
        }
        var out: [UtteranceExcerpt] = []
        for row in links {
            guard let jsonPath = row["json_path"] as String? else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            // SessionTranscript lives in HarcClient — to avoid an import cycle here,
            // decode just the bits we need with a local DTO.
            struct SessionPartial: Decodable {
                struct Word: Decodable { let text: String; let startMs: Int; let endMs: Int }
                struct Speaker: Decodable { let speaker: Int; let startMs: Int; let endMs: Int }
                let words: [Word]
                let speakers: [Speaker]
            }
            guard let session = try? decoder.decode(SessionPartial.self, from: data) else { continue }
            let speakerIndex: Int = row["speaker_index"]
            let segments = session.speakers.filter { $0.speaker == speakerIndex }
            for seg in segments.prefix(3) {  // top-3 utterances per recording for v1
                let words = session.words.filter {
                    let mid = ($0.startMs + $0.endMs) / 2
                    return mid >= seg.startMs && mid < seg.endMs
                }
                let snippet = words.map(\.text).joined(separator: " ").prefix(120)
                let title = (row["title"] as String?)
                    ?? (row["suggested_title"] as String?)
                    ?? "Recording"
                out.append(UtteranceExcerpt(
                    recordingID: row["recording_id"],
                    recordingTitle: title,
                    speakerIndex: speakerIndex,
                    startMs: seg.startMs,
                    snippet: String(snippet)
                ))
            }
        }
        return out
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -3
git add -A
git commit -m "feat(ui): PersonDetailViewModel + stats + utterance fetcher

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 6.2: `PersonDetailView` (header + stats + utterances)

**Files:**
- Create: `Sources/HarcUI/PersonDetailView.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import HarcStore

public struct PersonDetailView: View {
    let personID: Int64
    @StateObject private var viewModel: PersonDetailViewModel
    let onSelectRecording: (Int64, Int) -> Void

    public init(personID: Int64, store: RecordingStore, onSelectRecording: @escaping (Int64, Int) -> Void) {
        self.personID = personID
        self.onSelectRecording = onSelectRecording
        _viewModel = StateObject(wrappedValue: PersonDetailViewModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stats = viewModel.stats { statsLine(stats) }
                utterancesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: personID) {
            await viewModel.load(personID: personID)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            PersonAvatar(displayName: viewModel.person?.displayName ?? "?", size: 44)
            Text(viewModel.person?.displayName ?? "Loading…")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            // Rename / Delete in Phase 7.
        }
    }

    @ViewBuilder
    private func statsLine(_ stats: PersonDetailViewModel.PersonStats) -> some View {
        HStack(spacing: 8) {
            Text("\(stats.recordingCount) recordings")
            Text("·").foregroundStyle(.secondary)
            Text(formatMs(stats.totalSpeakingMs)).foregroundStyle(.secondary)
            if let last = stats.lastSeen {
                Text("·").foregroundStyle(.secondary)
                Text("last seen \(last, style: .date)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var utterancesSection: some View {
        if !viewModel.utterances.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent utterances").font(.headline)
                ForEach(viewModel.utterances) { u in
                    Button {
                        onSelectRecording(u.recordingID, u.speakerIndex)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(u.recordingTitle).font(.subheadline.weight(.semibold))
                                Text("·").foregroundStyle(.secondary)
                                Text(formatTimestamp(u.startMs)).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(u.snippet).font(.body).lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total / 60) % 60
        if h > 0 { return "\(h)h \(m)m total" }
        return "\(m)m total"
    }

    private func formatTimestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

- [ ] **Step 2: Wire into HarcWindowRootView's detail pane**

In the detail builder:

```swift
@ViewBuilder
private var detail: some View {
    switch selection {
    case .recording, .none:
        if let recording = selectedRecording {
            // existing detailContent(recording:) call
        } else {
            // existing ContentUnavailableView
        }
    case .person(let id):
        PersonDetailView(personID: id, store: store) { recID, speakerIndex in
            // Switch the selection to the recording so the detail pane swaps.
            if let rec = libraryVM.recordings.first(where: { $0.id == recID }) {
                selection = .recording(wavPath: rec.wavPath)
            }
        }
    }
}
```

- [ ] **Step 3: Build + smoke + commit**

```bash
swift build && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -5
git add -A
git commit -m "feat(library): PersonDetailView — header, stats, utterance list

Power-tools sections (suggestions, voice prints, merge/split, threshold)
land in Phase 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 7 — `PersonDetailView` power tools

### Task 7.1: Suggested matches section + Confirm/Skip + Confirm all

Extend `PersonDetailViewModel` with `pendingSuggestions: [PendingSuggestion]` populated in `load(personID:)`. Add a section to the view that renders each suggestion with Confirm / Skip buttons calling `store.confirmSuggestion(...)` / `store.dismissSuggestion(...)`.

- [ ] **Step 1: VM changes**

```swift
@Published public private(set) var pendingSuggestions: [PendingSuggestion] = []

// in load(personID:):
pendingSuggestions = (try? await store.fetchPendingSuggestions(personID: personID)) ?? []

public func confirm(_ suggestion: PendingSuggestion) async {
    try? await store.confirmSuggestion(personID: suggestion.personID, recordingID: suggestion.recordingID, speakerIndex: suggestion.speakerIndex)
    await reloadSuggestions()
}
public func dismiss(_ suggestion: PendingSuggestion) async {
    try? await store.dismissSuggestion(personID: suggestion.personID, recordingID: suggestion.recordingID, speakerIndex: suggestion.speakerIndex)
    await reloadSuggestions()
}
public func confirmAll() async {
    for s in pendingSuggestions {
        try? await store.confirmSuggestion(personID: s.personID, recordingID: s.recordingID, speakerIndex: s.speakerIndex)
    }
    await reloadSuggestions()
}
private func reloadSuggestions() async {
    guard let id = person?.id else { return }
    pendingSuggestions = (try? await store.fetchPendingSuggestions(personID: id)) ?? []
}
```

- [ ] **Step 2: View section**

Insert above `utterancesSection`:

```swift
@ViewBuilder
private var suggestionsSection: some View {
    if !viewModel.pendingSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggested matches (\(viewModel.pendingSuggestions.count))").font(.headline)
                Spacer()
                Button("Confirm all") {
                    Task { await viewModel.confirmAll() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ForEach(viewModel.pendingSuggestions) { s in
                HStack(spacing: 8) {
                    Text("Recording #\(s.recordingID) Speaker \(s.speakerIndex + 1)")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", s.score))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Confirm") {
                        Task { await viewModel.confirm(s) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Skip") {
                        Task { await viewModel.dismiss(s) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(library): suggested matches section in PersonDetailView

Confirm / Skip per row + Confirm all batch action.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7.2: Voice prints + Merge + Split

Add an `embeddings: [SpeakerEmbeddingRow]` published array. Each row in the UI is multi-selectable; Merge prompts a Person picker, Split prompts a name.

- [ ] **Step 1: VM additions**

```swift
@Published public private(set) var embeddings: [SpeakerEmbeddingRow] = []

// in load:
embeddings = (try? await store.fetchEmbeddingsForPerson(personID, embedderKind: .wespeakerV2)) ?? []

public func split(slots: [(Int64, Int)], newName: String) async {
    _ = try? await store.splitEmbeddings(slots: slots.map { (recordingID: $0.0, speakerIndex: $0.1) }, intoNewPersonNamed: newName)
    if let id = person?.id { await load(personID: id) }
}

public func merge(into targetID: Int64) async {
    guard let id = person?.id else { return }
    try? await store.mergePeople(sourceIDs: [id], into: targetID)
    // After merge, this Person no longer exists — caller should navigate away.
}
```

- [ ] **Step 2: View section**

```swift
@State private var selectedSlots: Set<String> = []
@State private var showingMergeSheet = false
@State private var showingSplitSheet = false

@ViewBuilder
private var voicePrintsSection: some View {
    if !viewModel.embeddings.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice prints (\(viewModel.embeddings.count))").font(.headline)
                Spacer()
                Button("Merge…") { showingMergeSheet = true }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Split…") { showingSplitSheet = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(selectedSlots.isEmpty)
            }
            ForEach(viewModel.embeddings, id: \.slotKey) { e in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selectedSlots.contains(e.slotKey) },
                        set: { isOn in
                            if isOn { selectedSlots.insert(e.slotKey) }
                            else { selectedSlots.remove(e.slotKey) }
                        }
                    ))
                    .labelsHidden()
                    Text("Recording #\(e.recordingID) Speaker \(e.speakerIndex + 1)")
                    Spacer()
                    Text("\(e.segmentCount) segs · \(e.totalMs / 1000)s · \(e.embedderKind.rawValue)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
        .sheet(isPresented: $showingMergeSheet) {
            MergePersonPicker(allPeople: /* load via VM */ []) { targetID in
                Task { await viewModel.merge(into: targetID) }
                showingMergeSheet = false
            }
        }
        .sheet(isPresented: $showingSplitSheet) {
            SplitNameSheet { newName in
                let slots = selectedSlots.compactMap { key -> (Int64, Int)? in
                    let parts = key.split(separator: "-")
                    guard parts.count == 2, let r = Int64(parts[0]), let s = Int(parts[1]) else { return nil }
                    return (r, s)
                }
                Task { await viewModel.split(slots: slots, newName: newName) }
                selectedSlots.removeAll()
                showingSplitSheet = false
            }
        }
    }
}

private extension SpeakerEmbeddingRow {
    var slotKey: String { "\(recordingID)-\(speakerIndex)" }
}
```

`MergePersonPicker` and `SplitNameSheet`: small forms (~40 lines each). MergePersonPicker should fetch People from the store (excluding the current Person) and present a Picker.

- [ ] **Step 3: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(library): voice-prints section with multi-select Merge / Split

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7.3: Per-Person threshold slider

Add a slider 0.50–0.95 bound to `person.matchThreshold` (nil = default). "Reset to default" sets back to nil. Persists via `store.updatePersonThreshold(...)`.

- [ ] **Step 1: Store method**

```swift
public extension RecordingStore {
    func updatePersonThreshold(personID: Int64, threshold: Double?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE people SET match_threshold = ?, updated_at = ? WHERE id = ?",
                arguments: [threshold, Date().timeIntervalSince1970, personID]
            )
        }
    }
}
```

- [ ] **Step 2: VM + view**

```swift
public func updateThreshold(_ value: Double?) async {
    guard let id = person?.id else { return }
    try? await store.updatePersonThreshold(personID: id, threshold: value)
    if let id = person?.id { await load(personID: id) }
}

// View:
@ViewBuilder
private var thresholdSection: some View {
    if let person = viewModel.person {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match threshold").font(.headline)
            HStack {
                Slider(value: Binding(
                    get: { person.matchThreshold ?? 0.65 },
                    set: { v in Task { await viewModel.updateThreshold(v) } }
                ), in: 0.50...0.95)
                Text(String(format: "%.2f", person.matchThreshold ?? 0.65))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 40)
                if person.matchThreshold != nil {
                    Button("Reset") {
                        Task { await viewModel.updateThreshold(nil) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("Higher threshold = fewer false matches, more missed matches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(library): per-Person match threshold slider

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 7.4: Header Rename + Delete actions

Rename: inline-editable text field. Delete: confirms via alert with the spec's message; on confirm calls `store.deletePerson(...)` and clears `selection`.

- [ ] **Step 1: Update header**

```swift
private var header: some View {
    HStack(spacing: 12) {
        PersonAvatar(displayName: viewModel.person?.displayName ?? "?", size: 44)
        TextField("Name", text: Binding(
            get: { viewModel.person?.displayName ?? "" },
            set: { newName in Task { await viewModel.rename(to: newName) } }
        ))
        .textFieldStyle(.plain)
        .font(.title2)
        .fontWeight(.semibold)
        Spacer()
        Button(role: .destructive) { showingDeleteConfirm = true } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    .alert("Delete \(viewModel.person?.displayName ?? "")?", isPresented: $showingDeleteConfirm) {
        Button("Delete", role: .destructive) {
            Task {
                if let id = viewModel.person?.id {
                    try? await viewModel.delete()
                    onPersonDeleted?()
                }
            }
        }
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("\(viewModel.embeddings.count) voice prints unlink, \(viewModel.stats?.recordingCount ?? 0) recordings revert to 'Speaker N' labels. Audio + embeddings are not deleted.")
    }
}
```

VM:
```swift
public func rename(to newName: String) async {
    guard let id = person?.id else { return }
    try? await store.renamePerson(id: id, to: newName)
    person?.displayName = newName
}

public func delete() async throws {
    guard let id = person?.id else { return }
    try await store.deletePerson(id: id)
}
```

`PersonDetailView` gets an `onPersonDeleted: (() -> Void)?` init param so the parent can clear `selection`.

- [ ] **Step 2: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(library): Rename + Delete in PersonDetailView header

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 8 — Inspector autocomplete + suggestion chip

### Task 8.1: Suggestion chip in `SpeakerInspectorSection`

**Files:**
- Modify: `Sources/HarcUI/Inspector/SpeakerInspectorSection.swift`

- [ ] **Step 1: Add a `pendingSuggestions: [PendingSuggestion]` parameter**

The Inspector section already takes a recording-scoped context. Pass `pendingSuggestions: [PendingSuggestion]` (filtered to this recording) plus `onConfirmSuggestion:` and `onDismissSuggestion:` closures.

- [ ] **Step 2: Render the chip per speaker**

For each speaker row, look up `pendingSuggestions.first(where: { $0.speakerIndex == thisSpeakerIndex })`. If found, render below the name field:

```swift
HStack(spacing: 6) {
    Image(systemName: "questionmark.circle.fill").foregroundStyle(Color.yellow)
    Text("May be \(personName) · \(String(format: "%.2f", suggestion.score))")
        .font(.caption)
    Spacer()
    Button("Confirm") { onConfirmSuggestion(suggestion) }
        .buttonStyle(.borderedProminent).controlSize(.mini)
    Button("Dismiss") { onDismissSuggestion(suggestion) }
        .buttonStyle(.bordered).controlSize(.mini)
}
.padding(.horizontal, 8)
.padding(.vertical, 4)
.background(Capsule().fill(Color.yellow.opacity(0.12)))
```

- [ ] **Step 3: Wire from `HarcWindowRootView.inspectorContent`**

Load `pendingSuggestions` for the current recording:
```swift
@State private var inspectorPendingSuggestions: [PendingSuggestion] = []

.task(id: selectedRecording?.id) {
    if let id = selectedRecording?.id {
        inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
    } else {
        inspectorPendingSuggestions = []
    }
}
```

Pass into `SpeakerInspectorSection(pendingSuggestions: inspectorPendingSuggestions, onConfirmSuggestion: { s in Task { try? await store.confirmSuggestion(...) ; reload } }, ...)`.

- [ ] **Step 4: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(inspector): per-speaker suggestion chip with Confirm/Dismiss

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 8.2: People autocomplete on the rename field

Wrap the existing speaker-name `TextField` in a small autocomplete popover. As the user types, show matching `Person.displayName`s; selecting one calls `linkSpeaker(personID:recordingID:speakerIndex:)` instead of free-text rename.

(For a minimal v1: replace the `TextField` with a `Picker` that lists existing People + a "Create new…" option. Cleaner than building a custom autocomplete.)

- [ ] **Step 1: Add a `Menu`-style picker per speaker row**

```swift
Menu {
    ForEach(allPeople) { p in
        Button(p.displayName) {
            Task {
                try? await store.linkSpeaker(personID: p.id, recordingID: recordingID, speakerIndex: thisSpeakerIndex)
            }
        }
    }
    Divider()
    Button("Add new person…") {
        showingAddPersonSheet = true
    }
} label: {
    HStack {
        Text(currentLabel).foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.down").foregroundStyle(.secondary)
    }
}
```

`allPeople` is loaded via `.task` on the section.

- [ ] **Step 2: Build + commit**

```bash
swift build && git add -A
git commit -m "feat(inspector): People picker for speaker labels

Pick existing People from a Menu; 'Add new person…' creates one.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 9 — AppDelegate hookup

### Task 9.1: Run `SpeakerSuggestionEngine.suggestForRecording` after embeddings persist

**Files:**
- Modify: `HarcApp/AppDelegate.swift`

- [ ] **Step 1: Find the post-embeddings-persist site**

Look for the place in `stopRecording` where `store.upsertSpeakerEmbeddings(...)` succeeds. Right after that, kick off the engine:

```swift
Task.detached { [store] in
    let engine = SpeakerSuggestionEngine(store: store, embedderKind: .wespeakerV2)
    try? await engine.suggestForRecording(recordingID: id)
}
```

- [ ] **Step 2: Run rename-backfill when a new Person is created**

Wherever `store.createPerson(...)` + `store.linkSpeaker(...)` are called (Inspector "Add new person…" path), also call `engine.suggestForNewPerson(...)`.

- [ ] **Step 3: Build + commit**

```bash
swift build && xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -3
git add -A
git commit -m "feat(app): wire SpeakerSuggestionEngine into post-stop and rename flows

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 10 — Cleanup, build, push

### Task 10.1: Final size + acceptance

- [ ] **Step 1: Run full test suite**

```bash
swift test 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build 2>&1 | tail -3
```

Both green. Test count should be original baseline + ~20 (PeopleStoreTests + SpeakerSuggestionEngineTests).

- [ ] **Step 2: Manual smoke (per spec §9)**

- Start with no People. Record three meetings with two speakers each. In recording 1, label Speaker 2 as "Sarah." Verify pending suggestions appear in recordings 2 and 3 (Inspector chip) + in Sarah's detail view.
- Confirm one suggestion. Verify the recording's labels update everywhere (sidebar list, transcript turns, summary card, prompt-paste blob).
- Dismiss one suggestion. Verify it doesn't reappear after re-running diarize.
- Merge two People. Verify all linkages move and the source disappears.
- Split: pick two embeddings under "Sarah" and split into "Sarah work." Verify the slot relabels everywhere.
- Adjust per-Person threshold up; new recordings should produce fewer suggestions for that Person.
- Delete a Person. Recordings should revert to "Speaker N" labels; embeddings stay on disk.

- [ ] **Step 3: Push + open PR**

```bash
git push -u origin feat/speakers-library-2026-05-03
gh pr create --title "Speakers library" --body "$(cat <<'EOF'
## Summary

- New People entity layer: `people`, `person_speakers`, `pending_suggestions`, `dismissed_suggestions` tables (DB v10)
- Sidebar People section + per-Person detail view (header, stats, suggestions, utterances, voice prints, merge/split, threshold)
- Suggest-and-confirm flow: triggered after diarization (new recording) and after rename (cross-recording backfill)
- Inspector gains a Person picker + suggestion chip per speaker
- All speaker label reads now go through `RecordingStore.resolvedSpeakerName(...)`

Spec: `docs/superpowers/specs/2026-05-03-speakers-library-design.md`
Plan: `docs/superpowers/plans/2026-05-03-speakers-library.md`

## Test plan
- [ ] Label a speaker as "Sarah" in one recording; verify pending suggestions appear in past recordings within ~1s of opening them
- [ ] Confirm a suggestion → labels update everywhere (sidebar, transcript turns, summary card, prompt blob, exports)
- [ ] Dismiss a suggestion → it doesn't reappear
- [ ] Merge two People → all linkages move, source disappears
- [ ] Split selected embeddings → new Person, slot relabels
- [ ] Adjust per-Person threshold → fewer suggestions
- [ ] Delete a Person → recordings revert to "Speaker N"; embeddings stay on disk

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the executing agent

- **TDD strictly for store code** (Phases 0–4). Each task: write the test, run it, fail, implement, run, pass, commit.
- **UI tasks (Phases 5–8) verify via build + manual smoke.** SwiftUI views aren't unit-tested in this codebase pattern (the existing project follows the same convention).
- **`HarcStoreTests` uses XCTest** (NOT Swift Testing), per the existing files.
- **`HarcUITests` uses Swift Testing** (`import Testing`, `@Test`, `#expect`).
- **The `dbQueue` / `dbReader` accessor names** on `RecordingStore` may differ from what's shown above; verify against the existing extensions in `RecordingStore.swift` before writing the new ones.
- **Don't skip the label-resolver fan-out (Phase 3).** It's the single point where Person-aware names get plumbed into the entire UI; skipping it means the Person feature is invisible everywhere except the People sidebar.
- **The suggestion engine queries are O(persons × person-embeddings × new-embeddings) per recording.** With 50 People × ~5 embeddings each × 3 new embeddings, that's 750 cosine comparisons per stop — well under 100ms. If perf becomes an issue at scale, batch the embedding queries into a single SELECT.
