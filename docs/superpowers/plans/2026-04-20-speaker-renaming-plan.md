# Speaker Renaming + Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-recording speaker name overrides (`Speaker 1 → Jason`, etc.) in a new `recordings.speaker_names` column, thread them through the export pipeline via a single `SpeakerLabel.displayLabel` helper, emit a conditional `participants:` line in the prompt front-matter, and expose an inline editor in `TranscriptionDetailView`.

**Design doc:** `/Users/jlane/GitHub/Harc/docs/superpowers/specs/2026-04-20-speaker-renaming-design.md`

**Architecture:** `Recording.speakerNames: [Int: String]` (default `[:]`) is serialised as JSON in a new nullable `speaker_names` column (migration v5). `ExportInput.speakerNames` threads it into the renderers. A pure `SpeakerLabel.displayLabel(for:names:)` helper in `HarcExport` owns the fallback-or-override decision, consumed by `MarkdownExporter`, `DocxExporter`, and `PromptFrontMatter`. `PromptFrontMatter` emits a `participants:` line between `tags:` and `speakers:` when a diarized recording has any override. A new `SpeakerNameEditor` SwiftUI view in `TranscriptionDetailView` handles inline editing via a new `onSpeakerNamesChanged: ([Int: String]) -> Void` callback, mirroring the existing `onRename` pattern.

**Tech Stack:** Swift 6, GRDB migrations, Swift Testing, SwiftUI/AppKit (Form + TextField), FluidAudio (unchanged).

---

## Dependency graph

```
T1 (migration v5 + Recording.speakerNames Codable + round-trip)
  └─▶ T2 (RecordingStore.updateSpeakerNames)

T3 (ExportInput.speakerNames)
  └─▶ T4 (ExportInputBuilder threading)

T5 (SpeakerLabel pure helper)
  │
  └─▶ T6 (MarkdownExporter uses helper)
  └─▶ T7 (DocxExporter uses helper)
  └─▶ T8 (PromptFrontMatter participants: line)

T9 (SpeakerNameEditor SwiftUI view)
  └─▶ T10 (TranscriptionDetailView + window controller + AppDelegate wiring)
           └─▶ T11 (end-to-end manual verification)
```

Tasks 1, 3, 5, 9 are independent starts. T2 depends on T1. T4 depends on T3. T6/T7/T8 depend on T3 and T5. T10 depends on T9 (and implicitly on T1/T2 so the callback has something to write to). T11 is the gate.

---

## Effort summary

| Task | Effort | Gates |
|------|--------|-------|
| 1. Migration v5 + `Recording.speakerNames` + round-trip tests | S | `swift test --filter RecordingStoreTests` |
| 2. `RecordingStore.updateSpeakerNames` + tests | S | `swift test --filter RecordingStoreTests` |
| 3. `ExportInput.speakerNames` field + tests | S | `swift test --filter ExportInputTests` |
| 4. `ExportInputBuilder` threads speakerNames + tests | S | `swift test --filter ExportInputBuilderTests` |
| 5. `SpeakerLabel` pure helper + tests | S | `swift test --filter SpeakerLabelTests` |
| 6. `MarkdownExporter` uses `SpeakerLabel` + new tests | S | `swift test --filter MarkdownExporterTests` |
| 7. `DocxExporter` uses `SpeakerLabel` | S | `swift test --filter DocxExporterTests` |
| 8. `PromptFrontMatter` `participants:` line + new tests | M | `swift test --filter PromptFrontMatterTests` |
| 9. `SpeakerNameEditor` SwiftUI view | S | `swift build` |
| 10. `TranscriptionDetailView` + window controller + AppDelegate wiring | M | `xcodebuild` + manual |
| 11. End-to-end manual verification | S | full `swift test`, smoke checklist |

---

### Task 1: Migration v5 + `Recording.speakerNames` + round-trip

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcStore/DatabaseMigrator+Harc.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcStore/Recording.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/RecordingStoreTests.swift`

- [ ] **Step 1: Write the failing round-trip test**

Append inside `struct RecordingStoreTests` in `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/RecordingStoreTests.swift`, just after the existing `tagsEmptyDefault` test:

```swift
    @Test("speakerNames round-trip through the DB (dict)")
    func speakerNamesRoundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(Recording(
            wavPath: "/tmp/spk/a.wav",
            startedAt: Date(),
            speakerNames: [0: "Jason", 1: "Amy"]
        ))
        let fetched = try #require(try await store.fetchByWavPath("/tmp/spk/a.wav"))
        #expect(fetched.speakerNames == [0: "Jason", 1: "Amy"])
    }

    @Test("empty speakerNames reads back as empty, not nil")
    func speakerNamesEmptyDefault() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(Recording(wavPath: "/tmp/spk/b.wav", startedAt: Date()))
        let fetched = try #require(try await store.fetchByWavPath("/tmp/spk/b.wav"))
        #expect(fetched.speakerNames == [:])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RecordingStoreTests`
Expected: compile error — `Recording` initializer has no `speakerNames:` parameter.

- [ ] **Step 3: Register migration `v5_speaker_names`**

In `/Users/jlane/GitHub/Harc/Sources/HarcStore/DatabaseMigrator+Harc.swift`, append a new migration AFTER the existing `v4_fts_transcript_only` block and BEFORE the `return migrator` line:

```swift
        migrator.registerMigration("v5_speaker_names") { db in
            try db.alter(table: "recordings") { t in
                t.add(column: "speaker_names", .text)  // JSON-encoded [String: String]; nil means no overrides
            }
        }
```

- [ ] **Step 4: Add `speakerNames` to `Recording`**

In `/Users/jlane/GitHub/Harc/Sources/HarcStore/Recording.swift`:

**(a)** Add the property after the existing `tags` property:

```swift
    public var tags: [String] = []
    public var speakerNames: [Int: String] = [:]
    public var pinned: Bool
```

**(b)** Add `speakerNames` to the memberwise initializer. Insert after the existing `tags` parameter (default `[:]`):

```swift
    public init(
        id: Int64? = nil,
        wavPath: String,
        txtPath: String? = nil,
        jsonPath: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        transcriptText: String? = nil,
        suggestedTitle: String? = nil,
        tags: [String] = [],
        speakerNames: [Int: String] = [:],
        pinned: Bool = false,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
```

Assign it in the body, after the `self.tags = tags` line:

```swift
        self.tags = tags
        self.speakerNames = speakerNames
        self.pinned = pinned
```

**(c)** Add decode logic to the custom `init(from:)`. Insert after the existing `tags` decode block:

```swift
        if let json = try c.decodeIfPresent(String.self, forKey: .speakerNames),
           let data = json.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            var parsed: [Int: String] = [:]
            for (k, v) in raw {
                if let i = Int(k), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsed[i] = v
                }
            }
            self.speakerNames = parsed
        } else {
            self.speakerNames = [:]
        }
```

**(d)** Add encode logic to `encode(to:)`. Insert after the existing `tags` encode block:

```swift
        if speakerNames.isEmpty {
            try c.encodeNil(forKey: .speakerNames)
        } else {
            var stringKeyed: [String: String] = [:]
            for (k, v) in speakerNames { stringKeyed[String(k)] = v }
            if let data = try? JSONEncoder().encode(stringKeyed),
               let s = String(data: data, encoding: .utf8) {
                try c.encode(s, forKey: .speakerNames)
            } else {
                try c.encodeNil(forKey: .speakerNames)
            }
        }
```

**(e)** Add the CodingKeys case. Insert after the existing `tags` case:

```swift
        case tags
        case speakerNames = "speaker_names"
        case pinned
```

**(f)** Add the `Columns` constant. Insert after the existing `tags` column:

```swift
        static let tags = Column("tags")
        static let speakerNames = Column("speaker_names")
        static let pinned = Column("pinned")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter RecordingStoreTests`
Expected: all existing tests pass, plus the two new `speakerNames` tests.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all tests pass (the default `speakerNames: [:]` keeps all existing `Recording(...)` call sites compiling).

- [ ] **Step 7: Commit**

```bash
git add Sources/HarcStore/DatabaseMigrator+Harc.swift Sources/HarcStore/Recording.swift Tests/HarcStoreTests/RecordingStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(store): Recording.speakerNames + migration v5

New nullable speaker_names column on recordings, JSON-encoded
[String: String] with numeric string keys. Recording.speakerNames is
[Int: String] in Swift, default [:]. Decode converts string keys to
Int and drops empty-trim values defensively. Empty dict → NULL
(matches the tags pattern).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `RecordingStore.updateSpeakerNames`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcStore/RecordingStore.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/RecordingStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `struct RecordingStoreTests` near the other speaker-names tests:

```swift
    @Test("updateSpeakerNames writes the JSON-encoded dict and clears on empty")
    func updateSpeakerNamesBasics() async throws {
        let store = try await RecordingStore.inMemory()
        let rec = try await store.upsert(Recording(wavPath: "/tmp/usn/a.wav", startedAt: Date()))

        try await store.updateSpeakerNames(id: rec.id!, names: [0: "Jason", 2: "Amy"])
        let written = try #require(try await store.fetchByWavPath("/tmp/usn/a.wav"))
        #expect(written.speakerNames == [0: "Jason", 2: "Amy"])

        // Empty dict clears the column.
        try await store.updateSpeakerNames(id: rec.id!, names: [:])
        let cleared = try #require(try await store.fetchByWavPath("/tmp/usn/a.wav"))
        #expect(cleared.speakerNames == [:])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RecordingStoreTests`
Expected: compile error — `RecordingStore` has no `updateSpeakerNames`.

- [ ] **Step 3: Add `updateSpeakerNames`**

In `/Users/jlane/GitHub/Harc/Sources/HarcStore/RecordingStore.swift`, add a new method near the existing `updateTags(id:tags:)` (around line 139):

```swift
    /// Post-process path: set the per-recording speaker-name overrides.
    /// Empty dict clears the column (stored as NULL). No `notFound` throw —
    /// late updates are benign.
    public func updateSpeakerNames(id: Int64, names: [Int: String]) async throws {
        let json: String?
        if names.isEmpty {
            json = nil
        } else {
            var stringKeyed: [String: String] = [:]
            for (k, v) in names {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { stringKeyed[String(k)] = trimmed }
            }
            if stringKeyed.isEmpty {
                json = nil
            } else if let data = try? JSONEncoder().encode(stringKeyed),
                      let s = String(data: data, encoding: .utf8) {
                json = s
            } else {
                json = nil
            }
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recordings SET speaker_names = ?, updated_at = ? WHERE id = ?",
                arguments: [json, Date(), id]
            )
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RecordingStoreTests`
Expected: the new test passes, all existing ones still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcStore/RecordingStore.swift Tests/HarcStoreTests/RecordingStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(store): RecordingStore.updateSpeakerNames(id:names:)

Write-through for per-recording speaker overrides. Empty or all-empty
values clear the column to NULL. Whitespace-trimmed empty values are
dropped before encoding, so typing a space then saving behaves like
typing nothing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ExportInput.speakerNames`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInput.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `@Suite("ExportInput") struct ExportInputTests`:

```swift
    @Test("speakerNames defaults to empty when omitted")
    func speakerNamesDefaultsEmpty() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: []
        )
        #expect(input.speakerNames.isEmpty)
    }

    @Test("speakerNames round-trips via initializer")
    func speakerNamesRoundTrip() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: []
        )
        #expect(input.speakerNames == [0: "Jason", 1: "Amy"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExportInputTests`
Expected: compile error — `ExportInput` initializer has no `speakerNames:` parameter.

- [ ] **Step 3: Add `speakerNames` to `ExportInput`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInput.swift`:

**(a)** Add the stored property after the existing `tags`:

```swift
    public let tags: [String]
    public let speakerNames: [Int: String]
    public let segments: [Segment]
```

**(b)** Update the initializer — add `speakerNames: [Int: String] = [:]` between the existing `tags` and `segments` parameters, and the corresponding assignment:

```swift
    public init(
        title: String,
        startedAt: Date,
        durationSeconds: Int?,
        tags: [String] = [],
        speakerNames: [Int: String] = [:],
        segments: [Segment]
    ) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.speakerNames = speakerNames
        self.segments = segments
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ExportInputTests`
Expected: all `ExportInputTests` pass including the two new cases.

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests pass. All existing `ExportInput(...)` callers use named arguments and the new parameter is defaulted, so nothing breaks.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcExport/ExportInput.swift Tests/HarcExportTests/ExportInputTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportInput.speakerNames field (default empty dict)

Threaded by ExportInputBuilder (next task) and consumed by the renderer
stack via SpeakerLabel.displayLabel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `ExportInputBuilder` threads `speakerNames`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInputBuilder.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct ExportInputBuilderTests`:

```swift
    @Test("speakerNames flow from Recording.speakerNames into ExportInput")
    func speakerNamesFlow() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi",
            speakerNames: [0: "Jason", 1: "Amy"]
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.speakerNames == [0: "Jason", 1: "Amy"])
    }

    @Test("speakerNames defaults to empty when Recording has none")
    func speakerNamesEmptyByDefault() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.speakerNames.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExportInputBuilderTests`
Expected: the first new test fails — `input.speakerNames` is always empty because the builder doesn't yet thread the field.

- [ ] **Step 3: Thread `speakerNames` through `ExportInputBuilder.build(from:)`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInputBuilder.swift`, add `speakerNames: recording.speakerNames` to ALL THREE `ExportInput(...)` construction sites in `build(from:)` (the JSON-present branch, the `transcriptText` fallback branch, and the empty branch). Replace the `build(from:)` function body with:

```swift
    public static func build(from recording: Recording) -> ExportInput {
        let duration: Int? = recording.endedAt.map {
            max(0, Int($0.timeIntervalSince(recording.startedAt)))
        }
        let title = recording.displayTitle

        if let path = recording.jsonPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let transcript = try? decoder.decode(SessionTranscript.self, from: data) {
                let segments = collapseToSegments(transcript: transcript)
                return ExportInput(
                    title: title,
                    startedAt: recording.startedAt,
                    durationSeconds: duration,
                    tags: recording.tags,
                    speakerNames: recording.speakerNames,
                    segments: segments
                )
            }
        }

        if let text = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ExportInput(
                title: title,
                startedAt: recording.startedAt,
                durationSeconds: duration,
                tags: recording.tags,
                speakerNames: recording.speakerNames,
                segments: [.init(speaker: nil, text: text)]
            )
        }

        return ExportInput(
            title: title,
            startedAt: recording.startedAt,
            durationSeconds: duration,
            tags: recording.tags,
            speakerNames: recording.speakerNames,
            segments: []
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ExportInputBuilderTests`
Expected: all tests pass including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/ExportInputBuilder.swift Tests/HarcExportTests/ExportInputBuilderTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportInputBuilder threads Recording.speakerNames

All three build branches (JSON, transcriptText fallback, empty) now
include recording.speakerNames in the produced ExportInput.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `SpeakerLabel` pure helper

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/SpeakerLabel.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/SpeakerLabelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/SpeakerLabelTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcExport

@Suite("SpeakerLabel")
struct SpeakerLabelTests {
    @Test("nil speaker returns nil (un-diarized segment)")
    func nilSpeaker() {
        #expect(SpeakerLabel.displayLabel(for: nil, names: [:]) == nil)
        #expect(SpeakerLabel.displayLabel(for: nil, names: [0: "Jason"]) == nil)
    }

    @Test("missing override falls back to Speaker N (1-based)")
    func fallback() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [:]) == "Speaker 1")
        #expect(SpeakerLabel.displayLabel(for: 2, names: [0: "Jason"]) == "Speaker 3")
    }

    @Test("override name returned when present and non-empty")
    func overrideHit() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "Jason"]) == "Jason")
        #expect(SpeakerLabel.displayLabel(for: 1, names: [0: "Jason", 1: "Amy"]) == "Amy")
    }

    @Test("empty-trim override is treated as absent (fallback)")
    func emptyTrimFallback() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: ""]) == "Speaker 1")
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "   "]) == "Speaker 1")
    }

    @Test("override is trimmed before return")
    func trimmedOverride() {
        #expect(SpeakerLabel.displayLabel(for: 0, names: [0: "  Jason  "]) == "Jason")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SpeakerLabelTests`
Expected: compile error — `SpeakerLabel` does not exist.

- [ ] **Step 3: Create `SpeakerLabel.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcExport/SpeakerLabel.swift`:

```swift
import Foundation

/// Single source of truth for the user-visible speaker label. Consumed
/// by `MarkdownExporter`, `DocxExporter`, and `PromptFrontMatter` so the
/// fallback ("Speaker N") and the override lookup never drift across
/// renderers.
public enum SpeakerLabel {
    /// Returns the override name for `speaker` if present and non-empty
    /// after trim; otherwise `"Speaker \(speaker + 1)"`. Returns `nil`
    /// when `speaker` is `nil` (un-diarized segment — callers omit the
    /// prefix entirely).
    public static func displayLabel(for speaker: Int?, names: [Int: String]) -> String? {
        guard let id = speaker else { return nil }
        if let raw = names[id] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Speaker \(id + 1)"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SpeakerLabelTests`
Expected: all 5 test groups pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/SpeakerLabel.swift Tests/HarcExportTests/SpeakerLabelTests.swift
git commit -m "$(cat <<'EOF'
feat(export): SpeakerLabel.displayLabel pure helper

Single source of truth for speaker labels. Override-or-fallback logic
lives once, consumed by every renderer so Markdown / DOCX / front-matter
can't drift.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `MarkdownExporter` uses `SpeakerLabel`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/MarkdownExporter.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/MarkdownExporterTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the existing `@Suite` block in `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/MarkdownExporterTests.swift`:

```swift
    @Test("override names replace Speaker N in the body")
    func overrideNamesRender() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: [],
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "morning"),
                .init(speaker: 1, text: "hey"),
            ]
        )
        let out = MarkdownExporter.render(input)
        #expect(out.contains("Jason: morning"))
        #expect(out.contains("Amy: hey"))
        #expect(!out.contains("Speaker 1:"))
        #expect(!out.contains("Speaker 2:"))
    }

    @Test("partial override mixes names and Speaker N fallback")
    func partialOverride() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: [],
            speakerNames: [0: "Jason"],
            segments: [
                .init(speaker: 0, text: "morning"),
                .init(speaker: 1, text: "hey"),
            ]
        )
        let out = MarkdownExporter.render(input)
        #expect(out.contains("Jason: morning"))
        #expect(out.contains("Speaker 2: hey"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MarkdownExporterTests`
Expected: the two new tests fail — `MarkdownExporter` still hard-codes `Speaker \(speaker + 1)` and ignores `speakerNames`.

- [ ] **Step 3: Update `MarkdownExporter`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/MarkdownExporter.swift`, replace the `render(_:)` function's segment loop. Find:

```swift
    public static func render(_ input: ExportInput) -> String {
        var out = ""
        for segment in input.segments {
            let cleaned = sanitize(segment.text)
            guard !cleaned.isEmpty else { continue }
            if let speaker = segment.speaker {
                let label = "Speaker \(speaker + 1)"
                out += "\(label): \(cleaned)\n"
            } else {
                out += "\(cleaned)\n\n"
            }
        }
```

Replace with:

```swift
    public static func render(_ input: ExportInput) -> String {
        var out = ""
        for segment in input.segments {
            let cleaned = sanitize(segment.text)
            guard !cleaned.isEmpty else { continue }
            if let label = SpeakerLabel.displayLabel(for: segment.speaker, names: input.speakerNames) {
                out += "\(label): \(cleaned)\n"
            } else {
                out += "\(cleaned)\n\n"
            }
        }
```

The rest of the function (trailing-whitespace trim, trailing `\n`) is unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MarkdownExporterTests`
Expected: all tests pass — the two new override tests, plus every pre-existing test (the default-empty `speakerNames` case still produces `Speaker N` via the helper's fallback).

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/MarkdownExporter.swift Tests/HarcExportTests/MarkdownExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): MarkdownExporter uses SpeakerLabel.displayLabel

Diarized segments now consult the override dict via the pure helper.
Empty speakerNames preserves the Speaker N default; partial overrides
mix names with Speaker N fallbacks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `DocxExporter` uses `SpeakerLabel`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/DocxExporter.swift`

No new unit tests — DOCX assertions require decoding the OOXML blob, which is heavy and already covered at the smoke-test level. The SpeakerLabel logic itself is tested in Task 5.

- [ ] **Step 1: Update `DocxExporter`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/DocxExporter.swift`, find the `Speaker \(speaker + 1)` call site (around line 60). The exact surrounding code varies — read the file first to confirm the context.

Replace the single existing line that constructs the `"Speaker \(speaker + 1): "` label with a call through `SpeakerLabel.displayLabel`. The segment-speaker-nil branch (which currently omits the prefix for un-diarized paragraphs) stays structurally the same; both branches just route through the helper.

Concretely, find the block that looks like:

```swift
            if let speaker = segment.speaker {
                let label = "Speaker \(speaker + 1)"
                out.append(NSAttributedString(string: "\(label): ", attributes: labelAttrs))
                out.append(NSAttributedString(string: "\(cleaned)\n", attributes: bodyAttrs))
            } else {
                out.append(NSAttributedString(string: "\(cleaned)\n\n", attributes: bodyAttrs))
            }
```

Replace with:

```swift
            if let label = SpeakerLabel.displayLabel(for: segment.speaker, names: input.speakerNames) {
                out.append(NSAttributedString(string: "\(label): ", attributes: labelAttrs))
                out.append(NSAttributedString(string: "\(cleaned)\n", attributes: bodyAttrs))
            } else {
                out.append(NSAttributedString(string: "\(cleaned)\n\n", attributes: bodyAttrs))
            }
```

If the surrounding code uses different attribute variable names (e.g. `labelFont`, `bodyFont`) or a different NSAttributedString constructor, preserve that pattern — only the label-string construction and the outer `if` condition change.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Run the full suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests pass (DocxExporter's existing behaviour test should still pass — the default `speakerNames: [:]` keeps output byte-identical).

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcExport/DocxExporter.swift
git commit -m "$(cat <<'EOF'
feat(export): DocxExporter uses SpeakerLabel.displayLabel

Matches MarkdownExporter — the override / fallback decision lives once
in SpeakerLabel. Default empty speakerNames keeps DOCX output
byte-identical to pre-feature.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `PromptFrontMatter` `participants:` line

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct PromptFrontMatterTests`:

```swift
    @Test("render — emits participants line when all speakers overridden")
    func renderEmitsParticipantsFullOverride() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: Jason, Amy"))
        #expect(out.contains("speakers: 2"))
    }

    @Test("render — participants mixes names and Speaker N for partial override")
    func renderParticipantsPartial() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: Jason, Speaker 2"))
    }

    @Test("render — omits participants when speakerNames is empty")
    func renderOmitsParticipantsNoOverride() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("participants:"))
        #expect(out.contains("speakers: 2"))
    }

    @Test("render — omits participants for single-speaker recordings even with override")
    func renderOmitsParticipantsSingleSpeaker() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Jason"],
            segments: [.init(speaker: 0, text: "a")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("participants:"))
        #expect(!out.contains("speakers:"))
    }

    @Test("render — participants with a colon in a name forces quoting")
    func renderParticipantsQuotesColon() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 60,
            speakerNames: [0: "Foo: Bar", 1: "Amy"],
            segments: [
                .init(speaker: 0, text: "a"),
                .init(speaker: 1, text: "b"),
            ]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("participants: \"Foo: Bar, Amy\""))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptFrontMatterTests`
Expected: the five new tests fail — `participants:` is never emitted today.

- [ ] **Step 3: Update `PromptFrontMatter.render`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`, find the section of `render(_:timeZone:)` that emits the `speakers:` line (it currently looks approximately like):

```swift
        let speakers = speakerCount(in: input.segments)
        if speakers >= 2 {
            lines.append("speakers: \(speakers)")
        }
```

Replace with:

```swift
        let speakers = speakerCount(in: input.segments)
        if speakers >= 2, hasAnyOverride(input: input) {
            let joined = (0..<speakers).map { i -> String in
                if let raw = input.speakerNames[i] {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                return "Speaker \(i + 1)"
            }.joined(separator: ", ")
            lines.append("participants: \(yamlScalar(joined))")
        }
        if speakers >= 2 {
            lines.append("speakers: \(speakers)")
        }
```

Add the `hasAnyOverride` helper inside the `PromptFrontMatter` enum (alongside `speakerCount`):

```swift
    /// True iff `input.speakerNames` has at least one entry whose value
    /// is non-empty after trimming. Used to gate the `participants:`
    /// front-matter emission — otherwise the line would just be
    /// `Speaker 1, Speaker 2` which duplicates the `speakers:` count.
    static func hasAnyOverride(input: ExportInput) -> Bool {
        for (_, v) in input.speakerNames {
            if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return false
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all PromptFrontMatterTests pass, including the five new `participants:` cases and every pre-existing test.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter emits conditional participants: line

Between tags: and speakers:, when the recording has >= 2 distinct
speakers AND any override is set. Empty-override recordings omit the
line so Speaker 1, Speaker 2 isn't noise next to speakers: 2.
Participant names that contain a YAML indicator (e.g. a colon) force
the line to be quoted via yamlScalar.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `SpeakerNameEditor` SwiftUI view

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/SpeakerNameEditor.swift`

No unit tests — SwiftUI view with stateful editing, covered by manual smoke in Task 11.

- [ ] **Step 1: Create `SpeakerNameEditor.swift`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcUI/SpeakerNameEditor.swift`:

```swift
import SwiftUI
import HarcStore
import HarcExport

/// Inline editor showing one row per distinct speaker index present in
/// the recording. Users type display names; commits fire on Enter or
/// focus-loss via the `onCommit` callback. Visibility: the view renders
/// nothing when `speakerIndices` is empty (un-diarized recording).
public struct SpeakerNameEditor: View {
    private let speakerIndices: [Int]           // ascending, distinct
    private let initialNames: [Int: String]
    private let onCommit: ([Int: String]) -> Void

    @State private var draftNames: [Int: String]

    public init(
        speakerIndices: [Int],
        initialNames: [Int: String],
        onCommit: @escaping ([Int: String]) -> Void
    ) {
        self.speakerIndices = speakerIndices.sorted()
        self.initialNames = initialNames
        self.onCommit = onCommit
        self._draftNames = State(initialValue: initialNames)
    }

    public var body: some View {
        if speakerIndices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                Text("SPEAKERS")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .tracking(1.2)
                ForEach(speakerIndices, id: \.self) { index in
                    row(for: index)
                }
            }
        }
    }

    private func row(for index: Int) -> some View {
        HStack(spacing: HarcDesign.Space.sm) {
            Text("Speaker \(index + 1)")
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(Color.harcOnSurface)
                .frame(width: 90, alignment: .leading)
            TextField("Name (e.g. Jason)", text: binding(for: index))
                .textFieldStyle(.roundedBorder)
                .font(HarcDesign.Font.bodyMd)
                .onSubmit { commit() }
        }
    }

    /// Two-way binding into the `draftNames` dict. Reads return "" when
    /// the index has no entry so the TextField shows empty. Writes store
    /// the raw string; trimming happens at commit time.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { draftNames[index] ?? "" },
            set: { newValue in
                draftNames[index] = newValue
            }
        )
    }

    /// Normalise draftNames (trim, drop empty), compare against
    /// initialNames, fire callback only if changed.
    private func commit() {
        var normalised: [Int: String] = [:]
        for (k, v) in draftNames {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { normalised[k] = trimmed }
        }
        if normalised != initialNames {
            onCommit(normalised)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcUI/SpeakerNameEditor.swift
git commit -m "$(cat <<'EOF'
feat(ui): SpeakerNameEditor — inline speaker-name editor view

SwiftUI view rendering one labelled TextField per distinct speaker
index. Drafts held in @State; commit on Enter fires the onCommit
callback with a normalised dict (trimmed, empty values dropped). Emits
EmptyView for un-diarized recordings. Consumed next by
TranscriptionDetailView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: `TranscriptionDetailView` + window controller + AppDelegate wiring

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

Atomic change — the new `onSpeakerNamesChanged` init parameter on `TranscriptionDetailView` forces every call site to provide a closure, so the three files ship in one commit.

- [ ] **Step 1: Add the callback + integrate the editor in `TranscriptionDetailView`**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift`:

**(a)** Add the new callback field and include `HarcExport` import. Find the imports block at the top:

```swift
import SwiftUI
import AppKit
import HarcStore
import HarcExport
```

(The `HarcExport` import is already present from the Copy-for-Prompt feature; verify it's there and keep it.)

**(b)** Add the new stored property next to the existing callbacks:

```swift
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void
    let onSpeakerNamesChanged: ([Int: String]) -> Void
```

**(c)** Add the init parameter:

```swift
    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
        self.onSpeakerNamesChanged = onSpeakerNamesChanged
        self._renameDraft = State(initialValue: recording.title ?? "")
    }
```

**(d)** Add a computed helper for the editor + its visibility. Add this private helper near the existing `load()` method at the bottom:

```swift
    /// Distinct speaker indices present in the recording, discovered by
    /// re-using `ExportInputBuilder.build` (which reads the sibling .json
    /// once). Empty array when the recording is un-diarized.
    private var speakerIndices: [Int] {
        let input = ExportInputBuilder.build(from: recording)
        var seen: Set<Int> = []
        for s in input.segments {
            if let id = s.speaker { seen.insert(id) }
        }
        return seen.sorted()
    }
```

**(e)** Insert the editor into the body. The existing body layout is:

```swift
    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) { ... title + toolbar ... }
            if let loadError { ... } else if transcript.isEmpty { ... } else { ScrollView { ... } }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: load)
    }
```

Add `SpeakerNameEditor` between the title `HStack` and the transcript-or-error block. Modified body:

```swift
    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    if isEditingTitle {
                        TextField("Title", text: $renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(HarcDesign.Font.titleLg)
                            .onSubmit {
                                let cleaned = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                onRename(cleaned.isEmpty ? nil : cleaned)
                                isEditingTitle = false
                            }
                    } else {
                        Button {
                            isEditingTitle = true
                        } label: {
                            Text(recording.displayTitle)
                                .font(HarcDesign.Font.titleLg)
                                .foregroundStyle(Color.harcOnSurface)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(URL(fileURLWithPath: recording.wavPath).lastPathComponent)
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Spacer()
                toolbar
            }

            SpeakerNameEditor(
                speakerIndices: speakerIndices,
                initialNames: recording.speakerNames,
                onCommit: onSpeakerNamesChanged
            )

            if let loadError {
                Text(loadError)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcError)
            } else if transcript.isEmpty {
                Text("(no transcript)")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            } else {
                ScrollView {
                    Text(transcript)
                        .font(HarcDesign.Font.bodyMd)
                        .foregroundStyle(Color.harcOnSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(HarcDesign.Space.md)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
            }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: load)
    }
```

`SpeakerNameEditor` renders an `EmptyView` when `speakerIndices` is empty, so un-diarized recordings show nothing between title and transcript.

- [ ] **Step 2: Update the window controller**

In `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`, thread the new callback through. Replace the file contents with:

```swift
import AppKit
import SwiftUI
import HarcUI
import HarcStore

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void
    ) {
        let root = TranscriptionDetailView(
            recording: recording,
            onReveal: onReveal,
            onDelete: onDelete,
            onRename: onRename,
            onSpeakerNamesChanged: onSpeakerNamesChanged
        )
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
```

- [ ] **Step 3: Update the call site in `AppDelegate`**

In `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`, find the `openDetail(for:)` method's `TranscriptionDetailWindowController(...)` construction (around line 397). It currently looks like:

```swift
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            },
            onRename: { [weak self] newTitle in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.rename(id: id, title: newTitle) }
            }
        )
```

Add an `onSpeakerNamesChanged` closure. Replace with:

```swift
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            },
            onRename: { [weak self] newTitle in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.rename(id: id, title: newTitle) }
            },
            onSpeakerNamesChanged: { [weak self] names in
                guard let id = recording.id else { return }
                Task { try? await self?.store?.updateSpeakerNames(id: id, names: names) }
            }
        )
```

- [ ] **Step 4: Build and test**

Run: `swift build`
Expected: build succeeds.

Run: `swift test`
Expected: all tests pass. `TranscriptionDetailView` has no unit tests; build succeeding plus the existing store/export tests proves the protocol-level wiring.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds (ignore the pre-existing multi-destination warning).

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/TranscriptionDetailView.swift HarcApp/WindowControllers/TranscriptionDetailWindowController.swift HarcApp/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(ui): TranscriptionDetailView embeds SpeakerNameEditor

New onSpeakerNamesChanged callback on TranscriptionDetailView threads
through TranscriptionDetailWindowController to AppDelegate.openDetail,
which calls RecordingStore.updateSpeakerNames. SpeakerNameEditor is
rendered between the title block and the transcript; it renders as
EmptyView when the recording has no diarization, so un-diarized
recordings look unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: End-to-end manual verification

**Files:** none.

- [ ] **Step 1: Full test suite green**

Run: `swift test`
Expected: 0 failures. New tests: speakerNames round-trip (T1), updateSpeakerNames (T2), ExportInput.speakerNames (T3), ExportInputBuilder flow (T4), SpeakerLabel (T5 — 5 cases), MarkdownExporter override (T6 — 2 cases), PromptFrontMatter participants (T8 — 5 cases). Total new: ~16 additional test functions.

- [ ] **Step 2: Xcode build**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 3: Scan for new warnings**

Run: `swift build 2>&1 | grep -E 'warning:' | grep -vE 'TranscriptHitHighlight' || echo "no new warnings"`
Expected: `no new warnings`.

- [ ] **Step 4: Smoke — happy path (2 speakers, full override)**

Launch Harc. Record a ~30-second fixture with two speakers (you + a recorded voice on speakers, or two people). Stop. Open the transcription detail window (click "Read Full Transcript →" from the Library, or open from the stop popover).

Expect:
- A **SPEAKERS** section appears below the title, above the transcript, with rows `Speaker 1` and `Speaker 2` — each showing an empty TextField with placeholder "Name (e.g. Jason)".

Type `Jason` into Speaker 1's field and press Tab (focus-loss triggers commit). Type `Amy` into Speaker 2's field and press Enter. Close the detail window.

Re-open the detail window for the same recording. Expect:
- The TextFields are pre-populated with `Jason` and `Amy`.

Click **Copy for Prompt** (toolbar button). Paste into a text editor. Expect in the YAML front-matter:
- A line `participants: Jason, Amy` between `tags:` and `speakers:`.
- `speakers: 2` still present.
- The transcript body uses `Jason:` and `Amy:` instead of `Speaker 1:` / `Speaker 2:`.

- [ ] **Step 5: Smoke — partial override**

Re-open the same recording's detail. Clear Speaker 2's field (select-all + delete) and press Enter.

Copy for Prompt. Paste. Expect:
- Front-matter `participants: Jason, Speaker 2`.
- `speakers: 2` still present.
- Body shows `Jason: …` / `Speaker 2: …`.

- [ ] **Step 6: Smoke — clear all overrides**

Clear Speaker 1's field too. Copy for Prompt. Paste. Expect:
- **No** `participants:` line (gone when no overrides exist).
- `speakers: 2` still present.
- Body reverts to `Speaker 1:` / `Speaker 2:`.

- [ ] **Step 7: Smoke — un-diarized recording**

Record a short clip with only your voice (and Diarize toggle on). If the diarizer returns a single-speaker result, the detail view should show a SPEAKERS section with ONE row (`Speaker 1`) — you can still type a name. The front-matter `participants:` line is NOT emitted for single-speaker recordings (§3 invariant).

If you have a recording with no diarization at all (Diarize toggle off, or a legacy recording before diarization was added), open its detail view. Expect: no SPEAKERS section at all — just title, transcript, toolbar.

- [ ] **Step 8: Smoke — name with a colon**

In a 2-speaker recording, rename Speaker 1 to `Foo: Bar`. Copy for Prompt. Paste. Expect:
- Front-matter `participants: "Foo: Bar, Speaker 2"` (quoted because `Foo: Bar` contains a colon-space).

- [ ] **Step 9: Smoke — persistence across app restart**

With Speaker 1 renamed to `Jason` on a recording, quit Harc (Cmd-Q). Relaunch Harc. Open the same recording's detail view. Expect:
- The field is still `Jason`.

Copy for Prompt. Paste. Expect:
- Body still uses `Jason:` and the front-matter still contains the participant.

- [ ] **Step 10: Final tidy**

If anything surfaced during smoke that should live in the spec (e.g. a clarification), update `docs/superpowers/specs/2026-04-20-speaker-renaming-design.md` and commit separately. Otherwise no further commits.

---

## Self-review notes

- **Spec coverage.** §2 scope: column + migration → T1; `Recording.speakerNames` → T1; `RecordingStore.updateSpeakerNames` → T2; `ExportInput.speakerNames` → T3; `ExportInputBuilder` threading → T4; `SpeakerLabel` helper → T5; Markdown/DOCX/PromptFrontMatter use helper → T6/T7/T8; `SpeakerNameEditor` → T9; `TranscriptionDetailView` integration + callback wiring → T10; manual smoke → T11. §3 output rules covered across T4 (rules 1–3 via threading), T5 (rule 4: nil speaker handling), T8 (rule 5 on the `speakers:` comparison, rule 6 for the participants mix-fallback invariant). §4 rendering all covered. §5 UI editor covered by T9 + T10. §6 architecture map is a file-by-file mirror of the task list.
- **Type consistency.** `[Int: String]` is used consistently across `Recording`, `ExportInput`, `SpeakerLabel.displayLabel(for:names:)`, `SpeakerNameEditor`, `updateSpeakerNames`, `onSpeakerNamesChanged`. No drift to `[String: String]` or array forms at any boundary except the DB JSON serialisation (explicit conversion in T1 encode/decode).
- **Commit cadence.** One atomic commit per task. T10 is multi-file but lands in a single commit because the new `TranscriptionDetailView` init parameter forces all three files (view, window controller, AppDelegate) to update together. T7 has no test step because DOCX binary-format assertion isn't cost-effective; the helper is already tested in T5 and the default-empty case preserves byte-identical output.
- **Manual-smoke scope.** Restricted to surfaces this feature changes: the Speakers editor, the front-matter, the Markdown body. Doesn't re-verify recording, auto-paste, VAD, or search.
- **Migration path for existing installs.** The migration is additive (`ALTER TABLE ... ADD COLUMN`). Existing rows read back with `speaker_names = NULL`, which decodes to `speakerNames = [:]`, which renders as `Speaker N` — byte-identical behaviour to pre-feature for any user who doesn't touch the editor.
