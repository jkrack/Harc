# Speaker Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make speaker labels correct *within* a recording (full-WAV diarization at stop replaces broken per-chunk concatenation) and *across* recordings (FluidAudio's already-bundled WeSpeaker v2 embedder, surfaced through a new `diarize` IPC verb), in one coordinated rollout.

**Architecture:** A new `daemon.diarize(audioPath:)` IPC verb runs FluidAudio's full diarization pipeline on the final mixed WAV at end-of-recording, returning both `[SpeakerSegment]` and per-speaker WeSpeaker embeddings (256-dim, L2-normalized). `ChunkedTranscriber` calls per-chunk `transcribe(diarize: false)` during recording and a single `client.diarize(...)` call after the tail flush. Schema migration v9 wipes stub-embedder rows and adds an `embedder_kind` column. `StubSpeakerEmbedder`, the `SpeakerEmbedder` protocol, and `SpeakerExtractor` are deleted — the embedder lives inside FluidAudio. A new `RecordingPostProcessingState` `ObservableObject` drives a 3–10 s post-stop UX (status-item spinner, popover inline row, detail-view skeleton, retry on failure). Defaults flip: `speakerReIDEnabled = true`, threshold `0.62 → 0.65`. No backfill of existing recordings.

**Tech Stack:** Swift 6 / SwiftPM, GRDB/SQLite (migrations), FluidAudio 0.13.5+ (WeSpeaker v2 embedder), Swift Testing framework (`@Suite` / `@Test` / `#expect`), Combine + SwiftUI for HarcUI, `AVFoundation` for audio I/O.

**Spec:** [docs/superpowers/specs/2026-04-26-speaker-identity-design.md](../specs/2026-04-26-speaker-identity-design.md) — read for full design context. Commit `f9fdec0`.

---

## Phase A — Foundation (IPC types + storage schema)

These tasks touch `HarcCore`, `HarcVoiceprint`, and `HarcStore`. They have no behavioral effect on a running app yet — they prepare the wire format and DB shape that later tasks consume.

---

### Task 1: HarcCore IPC types — `DiarizeRequest`, `DiarizeResult`, `SpeakerEmbeddingRow`, new enum cases

**Files:**
- Modify: `Sources/HarcCore/IPCRequest.swift`
- Modify: `Sources/HarcCore/IPCResponse.swift`
- Test: `Tests/HarcCoreTests/IPCRoundTripTests.swift`

- [ ] **Step 1: Write failing test for `DiarizeRequest` round-trip**

Append to `Tests/HarcCoreTests/IPCRoundTripTests.swift`, inside the existing `@Suite("IPC round-trip")` struct:

```swift
@Test("DiarizeRequest round-trip")
func diarizeRequestRoundTrip() throws {
    let original = IPCRequest.diarize(DiarizeRequest(audioPath: "/tmp/audio.wav"))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
    #expect(decoded == original)
}

@Test("DiarizeResult round-trip")
func diarizeResultRoundTrip() throws {
    let result = DiarizeResult(
        segments: [
            SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2500),
        ],
        speakers: [
            SpeakerEmbeddingRow(
                speakerIndex: 0,
                vector: Array(repeating: Float(0.1), count: 256),
                totalMs: 1000,
                segmentCount: 1
            ),
            SpeakerEmbeddingRow(
                speakerIndex: 1,
                vector: Array(repeating: Float(-0.05), count: 256),
                totalMs: 1500,
                segmentCount: 1
            ),
        ],
        processingMs: 87
    )
    let original = IPCResponse.diarization(result)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
    #expect(decoded == original)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
swift test --filter HarcCoreTests.IPCRoundTripTests
```

Expected: compile failures for `IPCRequest.diarize`, `DiarizeRequest`, `DiarizeResult`, `IPCResponse.diarization`, `SpeakerEmbeddingRow`.

- [ ] **Step 3: Add `DiarizeRequest` and the new IPC request case**

Edit `Sources/HarcCore/IPCRequest.swift`. Replace its entire content with:

```swift
import Foundation

public enum IPCRequest: Codable, Equatable, Sendable {
    case transcribe(TranscribeRequest)
    case diarize(DiarizeRequest)
    case status
    case shutdown

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable { case transcribe, diarize, status, shutdown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .transcribe:
            self = .transcribe(try c.decode(TranscribeRequest.self, forKey: .payload))
        case .diarize:
            self = .diarize(try c.decode(DiarizeRequest.self, forKey: .payload))
        case .status:
            self = .status
        case .shutdown:
            self = .shutdown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transcribe(let r):
            try c.encode(Kind.transcribe, forKey: .type)
            try c.encode(r, forKey: .payload)
        case .diarize(let r):
            try c.encode(Kind.diarize, forKey: .type)
            try c.encode(r, forKey: .payload)
        case .status:
            try c.encode(Kind.status, forKey: .type)
        case .shutdown:
            try c.encode(Kind.shutdown, forKey: .type)
        }
    }
}

public struct TranscribeRequest: Codable, Equatable, Sendable {
    public var audioPath: String
    public var language: String
    public var wantTimestamps: Bool
    public var diarize: Bool
    public var vad: Bool

    public init(
        audioPath: String,
        language: String = "en",
        wantTimestamps: Bool = true,
        diarize: Bool = true,
        vad: Bool = true
    ) {
        self.audioPath = audioPath
        self.language = language
        self.wantTimestamps = wantTimestamps
        self.diarize = diarize
        self.vad = vad
    }

    private enum CodingKeys: String, CodingKey {
        case audioPath, language, wantTimestamps, diarize, vad
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.audioPath = try c.decode(String.self, forKey: .audioPath)
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.wantTimestamps = try c.decodeIfPresent(Bool.self, forKey: .wantTimestamps) ?? true
        self.diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? true
        self.vad = try c.decodeIfPresent(Bool.self, forKey: .vad) ?? true
    }
}

public struct DiarizeRequest: Codable, Equatable, Sendable {
    public var audioPath: String

    public init(audioPath: String) {
        self.audioPath = audioPath
    }
}
```

- [ ] **Step 4: Add `DiarizeResult`, `SpeakerEmbeddingRow`, and the new IPC response case**

Edit `Sources/HarcCore/IPCResponse.swift`. Replace its entire content with:

```swift
import Foundation

public enum IPCResponse: Codable, Equatable, Sendable {
    case result(TranscribeResult)
    case diarization(DiarizeResult)
    case status(DaemonStatus)
    case error(IPCError)

    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum Kind: String, Codable { case result, diarization, status, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .result:
            self = .result(try c.decode(TranscribeResult.self, forKey: .payload))
        case .diarization:
            self = .diarization(try c.decode(DiarizeResult.self, forKey: .payload))
        case .status:
            self = .status(try c.decode(DaemonStatus.self, forKey: .payload))
        case .error:
            self = .error(try c.decode(IPCError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let r):
            try c.encode(Kind.result, forKey: .type)
            try c.encode(r, forKey: .payload)
        case .diarization(let d):
            try c.encode(Kind.diarization, forKey: .type)
            try c.encode(d, forKey: .payload)
        case .status(let s):
            try c.encode(Kind.status, forKey: .type)
            try c.encode(s, forKey: .payload)
        case .error(let e):
            try c.encode(Kind.error, forKey: .type)
            try c.encode(e, forKey: .payload)
        }
    }
}

public struct TranscribeResult: Codable, Equatable, Sendable {
    public var text: String
    public var words: [Word]
    public var speakers: [SpeakerSegment]
    public var processingMs: Int

    public init(text: String, words: [Word], speakers: [SpeakerSegment], processingMs: Int) {
        self.text = text
        self.words = words
        self.speakers = speakers
        self.processingMs = processingMs
    }
}

public struct DiarizeResult: Codable, Equatable, Sendable {
    public var segments: [SpeakerSegment]
    public var speakers: [SpeakerEmbeddingRow]
    public var processingMs: Int

    public init(
        segments: [SpeakerSegment],
        speakers: [SpeakerEmbeddingRow],
        processingMs: Int
    ) {
        self.segments = segments
        self.speakers = speakers
        self.processingMs = processingMs
    }
}

public struct SpeakerEmbeddingRow: Codable, Equatable, Sendable {
    public var speakerIndex: Int
    public var vector: [Float]
    public var totalMs: Int
    public var segmentCount: Int

    public init(
        speakerIndex: Int,
        vector: [Float],
        totalMs: Int,
        segmentCount: Int
    ) {
        self.speakerIndex = speakerIndex
        self.vector = vector
        self.totalMs = totalMs
        self.segmentCount = segmentCount
    }
}

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct SpeakerSegment: Codable, Equatable, Sendable {
    public var speaker: Int
    public var startMs: Int
    public var endMs: Int
    public init(speaker: Int, startMs: Int, endMs: Int) {
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var version: String
    public var modelLoaded: Bool
    public var uptimeSeconds: Int
    public init(version: String, modelLoaded: Bool, uptimeSeconds: Int) {
        self.version = version
        self.modelLoaded = modelLoaded
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct IPCError: Codable, Equatable, Error, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```sh
swift test --filter HarcCoreTests.IPCRoundTripTests
```

Expected: all IPC round-trip tests pass, including the two new ones.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcCore/IPCRequest.swift Sources/HarcCore/IPCResponse.swift Tests/HarcCoreTests/IPCRoundTripTests.swift
git commit -m "$(cat <<'EOF'
feat(core): add diarize IPC verb + DiarizeResult / SpeakerEmbeddingRow

New IPCRequest.diarize(DiarizeRequest) and IPCResponse.diarization(DiarizeResult)
cases. SpeakerEmbeddingRow carries per-speaker WeSpeaker embedding output
(256-dim Float vector, totalMs, segmentCount) for storage in speaker_embeddings.
Existing TranscribeRequest.diarize remains as the per-chunk on/off knob.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: HarcVoiceprint — `EmbedderKind` constant

**Files:**
- Create: `Sources/HarcVoiceprint/EmbedderKind.swift`
- Test: `Tests/HarcVoiceprintTests/EmbedderKindTests.swift`

- [ ] **Step 1: Write failing test for `EmbedderKind.wespeakerV2`**

Create `Tests/HarcVoiceprintTests/EmbedderKindTests.swift`:

```swift
import Testing
@testable import HarcVoiceprint

@Suite("EmbedderKind")
struct EmbedderKindTests {
    @Test("wespeakerV2 has the canonical persisted string")
    func wespeakerV2Constant() {
        #expect(EmbedderKind.wespeakerV2 == "wespeaker_v2")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
swift test --filter HarcVoiceprintTests.EmbedderKindTests
```

Expected: compile failure — `EmbedderKind` not defined.

- [ ] **Step 3: Add the constant module**

Create `Sources/HarcVoiceprint/EmbedderKind.swift`:

```swift
import Foundation

/// Persisted identity of the speaker-embedder model that produced a
/// `speaker_embeddings` row. Stored as `embedder_kind TEXT` in the table.
///
/// Cross-recording cosine search filters to a single kind, so rows from a
/// different embedder become invisible to suggestions. Bumping the constant
/// is the migration mechanism for an embedder swap — no schema change
/// required, old rows just stop matching.
public enum EmbedderKind {
    /// FluidAudio's WeSpeaker v2 — 256-dim, L2-normalized.
    /// Bumped if FluidAudio ships a breaking change to the model
    /// or its output layout.
    public static let wespeakerV2: String = "wespeaker_v2"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```sh
swift test --filter HarcVoiceprintTests.EmbedderKindTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add Sources/HarcVoiceprint/EmbedderKind.swift Tests/HarcVoiceprintTests/EmbedderKindTests.swift
git commit -m "$(cat <<'EOF'
feat(voiceprint): add EmbedderKind constant

Identifies which embedder produced a stored embedding so cross-recording
cosine search can filter to comparable rows. v1 value: wespeaker_v2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: HarcStore — migration v9 (wipe stub rows, add `embedder_kind` column)

**Files:**
- Modify: `Sources/HarcStore/DatabaseMigrator+Harc.swift`
- Test: `Tests/HarcStoreTests/MigrationTests.swift`

- [ ] **Step 1: Write failing test for v9 — wipes existing rows and adds the column**

Append to `Tests/HarcStoreTests/MigrationTests.swift`, inside the existing `@Suite("DatabaseMigrator")` struct:

```swift
@Test("v9 wipes stub embeddings and adds embedder_kind column")
func v9WipesEmbeddingsAndAddsKindColumn() throws {
    let dbq = try DatabaseQueue()
    try DatabaseMigrator.harcMigrator().migrate(dbq)

    // Seed a v6-shape row directly via SQL — `embedder_kind` ends up NULL,
    // simulating a row that survived the migration without being wiped.
    try dbq.write { db in
        let now = Date()
        var rec = Recording(
            wavPath: "/tmp/v9-fixture.wav",
            startedAt: now,
            transcriptText: "x"
        )
        try rec.insert(db)
        // The v9 migration runs as part of the chain above, so by this
        // point the column exists and any pre-v9 rows have been deleted.
        try db.execute(
            sql: """
            INSERT INTO speaker_embeddings
            (recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [rec.id!, 0, Data(repeating: 0xAA, count: 1024), 3, 4500, "wespeaker_v2"]
        )
    }

    try dbq.read { db in
        let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(speaker_embeddings)")
        let names = cols.compactMap { $0["name"] as String? }
        #expect(names.contains("embedder_kind"), "v9 should add embedder_kind column; got \(names)")

        let rows = try Row.fetchAll(db, sql: "SELECT speaker_index, embedder_kind FROM speaker_embeddings")
        #expect(rows.count == 1)
        #expect(rows[0]["embedder_kind"] as String? == "wespeaker_v2")
    }
}

@Test("v9 deletes pre-existing v6 rows when running on a v8 fixture")
func v9DeletesPreExistingStubRows() throws {
    let dbq = try DatabaseQueue()

    // Stand up a v1..v8 migrator manually, seed a row, then run the full
    // (v1..v9) migrator over the same DB and assert v9's DELETE wiped it.
    var partial = DatabaseMigrator()
    let full = DatabaseMigrator.harcMigrator()
    // Replay the registered migrations in the same order, stopping at v8.
    // Easier: run the full migrator now (which already includes v9), then
    // we can't seed a pre-v9 row to test the DELETE. So we go the other
    // direction: build a stripped-down v8 migrator inline.
    partial.registerMigration("v1_recordings_and_fts") { db in
        try db.create(table: "recordings") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("wav_path", .text).notNull().unique()
            t.column("txt_path", .text)
            t.column("json_path", .text)
            t.column("started_at", .datetime).notNull()
            t.column("ended_at", .datetime)
            t.column("title", .text)
            t.column("transcript_text", .text)
            t.column("pinned", .boolean).notNull().defaults(to: false)
            t.column("deleted_at", .datetime)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
    }
    partial.registerMigration("v6_speaker_embeddings") { db in
        try db.create(table: "speaker_embeddings") { t in
            t.column("recording_id", .integer).notNull()
                .references("recordings", onDelete: .cascade)
            t.column("speaker_index", .integer).notNull()
            t.column("embedding", .blob).notNull()
            t.column("segment_count", .integer).notNull()
            t.column("total_ms", .integer).notNull()
            t.primaryKey(["recording_id", "speaker_index"])
        }
    }
    try partial.migrate(dbq)

    // Seed a recording + a stub-shaped 192-dim row.
    try dbq.write { db in
        try db.execute(
            sql: """
            INSERT INTO recordings (wav_path, started_at, pinned, created_at, updated_at)
            VALUES (?, ?, 0, ?, ?)
            """,
            arguments: ["/tmp/old.wav", Date(), Date(), Date()]
        )
        let recID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO speaker_embeddings
            (recording_id, speaker_index, embedding, segment_count, total_ms)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [recID, 0, Data(repeating: 0xCC, count: 768), 5, 8000]
        )

        let preCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") ?? -1
        #expect(preCount == 1, "expected 1 stub row before v9 runs, got \(preCount)")
    }

    // Now run the full migrator — its v9 step should DELETE the row and
    // add the embedder_kind column.
    try full.migrate(dbq)

    try dbq.read { db in
        let postCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM speaker_embeddings") ?? -1
        #expect(postCount == 0, "v9 should wipe pre-existing stub rows; got \(postCount)")

        let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(speaker_embeddings)")
        let names = cols.compactMap { $0["name"] as String? }
        #expect(names.contains("embedder_kind"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
swift test --filter HarcStoreTests.MigrationTests
```

Expected: the new tests fail because v9 doesn't exist; `embedder_kind` column missing.

- [ ] **Step 3: Add the v9 migration**

Edit `Sources/HarcStore/DatabaseMigrator+Harc.swift`. After the existing `v8_summary_status` registration block (just before the `return migrator` line at the bottom of `harcMigrator()`), insert:

```swift
        migrator.registerMigration("v9_speaker_embeddings_wespeaker") { db in
            // The v6 stub-embedder rows are 192-dim mel statistics — wrong
            // shape and wrong semantics for the WeSpeaker v2 vectors that
            // replace them. New recordings repopulate; pre-existing recordings
            // stay un-fingerprinted (no automatic backfill — see design doc).
            try db.execute(sql: "DELETE FROM speaker_embeddings")

            try db.alter(table: "speaker_embeddings") { t in
                // Versioned embedder identity. NULL means "unknown / pre-v9";
                // SpeakerReIDService filters to the current kind only, so old
                // rows are effectively invisible. New writes always set this.
                t.add(column: "embedder_kind", .text)
            }
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
swift test --filter HarcStoreTests.MigrationTests
```

Expected: all migration tests pass, including the two new v9 tests.

- [ ] **Step 5: Commit**

```sh
git add Sources/HarcStore/DatabaseMigrator+Harc.swift Tests/HarcStoreTests/MigrationTests.swift
git commit -m "$(cat <<'EOF'
feat(store): migration v9 — wipe stub embeddings, add embedder_kind

The v6 placeholder rows are 192-dim mel statistics, wrong shape for the
WeSpeaker v2 vectors that replace them. Wiped on v9 apply; pre-existing
recordings stay un-fingerprinted by design (no auto-backfill).

Adds embedder_kind TEXT column. NULL = pre-v9 / unknown; new writes
always set 'wespeaker_v2'. Cross-recording suggestion query filters by
kind so stale rows are silently invisible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: HarcStore — `RecordingStore` `embedderKind` parameter on upsert + query

**Files:**
- Modify: `Sources/HarcStore/RecordingStore.swift`
- Test: `Tests/HarcStoreTests/RecordingStoreSpeakerEmbeddingsTests.swift`

The existing `RecordingStore.SpeakerEmbeddingRow` (a *DB-row* type, distinct from `HarcCore.SpeakerEmbeddingRow`) gains an `embedderKind: String` field. Two methods gain a defaulted parameter.

- [ ] **Step 1: Write failing tests for the new column behavior**

Append to `Tests/HarcStoreTests/RecordingStoreSpeakerEmbeddingsTests.swift`:

```swift
@Test("upsertSpeakerEmbeddings writes embedder_kind column")
func upsertWritesEmbedderKind() async throws {
    let store = try await RecordingStore.inMemory()
    let rec = try await store.upsert(Recording(
        wavPath: "/tmp/k.wav",
        startedAt: Date(),
        transcriptText: "x"
    ))
    let row = RecordingStore.SpeakerEmbeddingRow(
        recordingID: rec.id!,
        speakerIndex: 0,
        embedding: Data(repeating: 0x11, count: 1024),
        segmentCount: 2,
        totalMs: 4000,
        embedderKind: "wespeaker_v2"
    )
    try await store.upsertSpeakerEmbeddings(recordingID: rec.id!, rows: [row])

    let fetched = try await store.speakerEmbedding(recordingID: rec.id!, speakerIndex: 0)
    #expect(fetched?.embedderKind == "wespeaker_v2")
}

@Test("allSpeakerEmbeddings(embedderKind:) filters to matching rows")
func allFiltersByEmbedderKind() async throws {
    let store = try await RecordingStore.inMemory()
    let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
    let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))
    let recC = try await store.upsert(Recording(wavPath: "/tmp/c.wav", startedAt: Date()))

    try await store.upsertSpeakerEmbeddings(
        recordingID: recA.id!,
        rows: [RecordingStore.SpeakerEmbeddingRow(
            recordingID: recA.id!, speakerIndex: 0,
            embedding: Data(repeating: 1, count: 1024),
            segmentCount: 1, totalMs: 5000,
            embedderKind: "wespeaker_v2"
        )]
    )
    try await store.upsertSpeakerEmbeddings(
        recordingID: recB.id!,
        rows: [RecordingStore.SpeakerEmbeddingRow(
            recordingID: recB.id!, speakerIndex: 0,
            embedding: Data(repeating: 2, count: 1024),
            segmentCount: 1, totalMs: 5000,
            embedderKind: "ecapa_v1"
        )]
    )
    try await store.upsertSpeakerEmbeddings(
        recordingID: recC.id!,
        rows: [RecordingStore.SpeakerEmbeddingRow(
            recordingID: recC.id!, speakerIndex: 0,
            embedding: Data(repeating: 3, count: 1024),
            segmentCount: 1, totalMs: 5000,
            embedderKind: "wespeaker_v2"
        )]
    )

    let weSpeaker = try await store.allSpeakerEmbeddings(
        excludingRecording: nil,
        embedderKind: "wespeaker_v2"
    )
    #expect(weSpeaker.count == 2)
    #expect(weSpeaker.allSatisfy { $0.embedderKind == "wespeaker_v2" })

    let ecapa = try await store.allSpeakerEmbeddings(
        excludingRecording: nil,
        embedderKind: "ecapa_v1"
    )
    #expect(ecapa.count == 1)
    #expect(ecapa[0].recordingID == recB.id!)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
swift test --filter HarcStoreTests.RecordingStoreSpeakerEmbeddingsTests
```

Expected: compile failures (`embedderKind` is not a member; `allSpeakerEmbeddings` doesn't take that parameter).

- [ ] **Step 3: Add `embedderKind` to `SpeakerEmbeddingRow` struct**

Edit `Sources/HarcStore/RecordingStore.swift`. Replace the existing `SpeakerEmbeddingRow` struct definition with:

```swift
    public struct SpeakerEmbeddingRow: Sendable, Equatable {
        public let recordingID: Int64
        public let speakerIndex: Int
        public let embedding: Data        // packed Float32
        public let segmentCount: Int
        public let totalMs: Int
        public let embedderKind: String?

        public init(
            recordingID: Int64,
            speakerIndex: Int,
            embedding: Data,
            segmentCount: Int,
            totalMs: Int,
            embedderKind: String? = nil
        ) {
            self.recordingID = recordingID
            self.speakerIndex = speakerIndex
            self.embedding = embedding
            self.segmentCount = segmentCount
            self.totalMs = totalMs
            self.embedderKind = embedderKind
        }
    }
```

- [ ] **Step 4: Update `upsertSpeakerEmbeddings` to write the column**

Replace the body of the `upsertSpeakerEmbeddings` method:

```swift
    public func upsertSpeakerEmbeddings(
        recordingID: Int64,
        rows: [SpeakerEmbeddingRow]
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM speaker_embeddings WHERE recording_id = ?",
                arguments: [recordingID]
            )
            for row in rows {
                precondition(row.recordingID == recordingID,
                             "upsertSpeakerEmbeddings: mixed recording ids in batch")
                try db.execute(
                    sql: """
                    INSERT INTO speaker_embeddings
                    (recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.recordingID,
                        row.speakerIndex,
                        row.embedding,
                        row.segmentCount,
                        row.totalMs,
                        row.embedderKind,
                    ]
                )
            }
        }
    }
```

- [ ] **Step 5: Update `speakerEmbedding(recordingID:speakerIndex:)` to read the column**

Replace its body:

```swift
    public func speakerEmbedding(recordingID: Int64, speakerIndex: Int) async throws -> SpeakerEmbeddingRow? {
        try await dbQueue.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                WHERE recording_id = ? AND speaker_index = ?
                """,
                arguments: [recordingID, speakerIndex]
            ) {
                return SpeakerEmbeddingRow(
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    embedding: row["embedding"],
                    segmentCount: row["segment_count"],
                    totalMs: row["total_ms"],
                    embedderKind: row["embedder_kind"]
                )
            }
            return nil
        }
    }
```

- [ ] **Step 6: Update `allSpeakerEmbeddings` to filter by kind**

Replace its body:

```swift
    public func allSpeakerEmbeddings(
        excludingRecording: Int64? = nil,
        embedderKind: String? = nil
    ) async throws -> [SpeakerEmbeddingRow] {
        try await dbQueue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []
            if let excluded = excludingRecording {
                clauses.append("recording_id != ?")
                args.append(excluded)
            }
            if let kind = embedderKind {
                clauses.append("embedder_kind = ?")
                args.append(kind)
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
                SELECT recording_id, speaker_index, embedding, segment_count, total_ms, embedder_kind
                FROM speaker_embeddings
                \(where_)
                """
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SpeakerEmbeddingRow(
                    recordingID: row["recording_id"],
                    speakerIndex: row["speaker_index"],
                    embedding: row["embedding"],
                    segmentCount: row["segment_count"],
                    totalMs: row["total_ms"],
                    embedderKind: row["embedder_kind"]
                )
            }
        }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

```sh
swift test --filter HarcStoreTests.RecordingStoreSpeakerEmbeddingsTests
swift test --filter HarcStoreTests
```

Expected: new tests pass; existing tests still pass (existing call sites pass `embedderKind: nil`, query falls through to its old WHERE-only-on-recording_id behavior).

- [ ] **Step 8: Commit**

```sh
git add Sources/HarcStore/RecordingStore.swift Tests/HarcStoreTests/RecordingStoreSpeakerEmbeddingsTests.swift
git commit -m "$(cat <<'EOF'
feat(store): RecordingStore embedderKind on speaker_embeddings rows

SpeakerEmbeddingRow gains optional embedderKind. upsertSpeakerEmbeddings
writes the embedder_kind column; allSpeakerEmbeddings(embedderKind:)
filters to matching rows so stale-kind embeddings are invisible to
cross-recording cosine search without a schema migration on swap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase B — Daemon-side diarization

These tasks change the daemon binary. After this phase the daemon supports the new `diarize` IPC verb and honors `transcribe.diarize: false` by skipping the diarizer entirely.

---

### Task 5: HarcSTT — `Diarizer.diarizeWithEmbeddings` returning segments + per-speaker embeddings

**Files:**
- Modify: `Sources/HarcSTT/Diarizer.swift`
- Test: `Tests/HarcSTTTests/DiarizerTests.swift`

The new method returns a value type carrying both the existing `[SpeakerSegment]` *and* a `[SpeakerEmbeddingRow]` (the HarcCore wire type — same shape used in `DiarizeResult`). The implementation prefers FluidAudio's `result.speakerDatabase` when non-nil and falls back to weighted-by-duration averaging of per-segment embeddings.

- [ ] **Step 1: Read `Sources/HarcSTT/Diarizer.swift` to confirm current shape**

```sh
cat Sources/HarcSTT/Diarizer.swift
```

The current public surface is `diarize(audioPath: String) async throws -> [SpeakerSegment]`. We're keeping it for the moment (still used by RequestHandler in the legacy `diarize=true` path until Task 6) and *adding* `diarizeWithEmbeddings`.

- [ ] **Step 2: Write failing test — happy-path `diarizeWithEmbeddings` returns segments + 256-dim embeddings**

Append to `Tests/HarcSTTTests/DiarizerTests.swift`. The repo currently has one STT fixture, `short-speech.wav` (a single-speaker clip). The integration test still validates the full end-to-end path — vector dimensionality, normalization, totalMs, segment-to-speaker consistency — against a real FluidAudio invocation; the multi-speaker correctness assertion is covered by the pure-helper tests in step 5 and by Manual QA Scenario 1.

```swift
@Test("diarizeWithEmbeddings returns 256-dim L2-normalized speaker embeddings")
func diarizeWithEmbeddingsReturnsVectors() async throws {
    let diarizer = Diarizer()
    try await diarizer.loadModels()

    let url = Bundle.module.url(forResource: "short-speech", withExtension: "wav")!
    let output = try await diarizer.diarizeWithEmbeddings(audioPath: url.path)

    #expect(!output.segments.isEmpty, "expected at least one segment")
    #expect(!output.speakers.isEmpty, "expected at least one speaker embedding")

    for sp in output.speakers {
        #expect(sp.vector.count == 256, "expected 256-dim, got \(sp.vector.count)")
        let normSq = sp.vector.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(abs(normSq - 1) < 0.05, "expected L2-normalized; got |v|² = \(normSq)")
        #expect(sp.totalMs > 0)
        #expect(sp.segmentCount > 0)
    }

    // Speaker-index space is consistent between the two arrays — every
    // segment.speaker has a matching speaker row.
    let segmentSpeakers = Set(output.segments.map(\.speaker))
    let speakerIndices = Set(output.speakers.map(\.speakerIndex))
    #expect(segmentSpeakers.isSubset(of: speakerIndices),
            "every segment speaker should have an embedding row")
}
```

- [ ] **Step 3: Run the test to verify it fails**

```sh
swift test --filter HarcSTTTests.DiarizerTests.diarizeWithEmbeddingsReturnsVectors
```

Expected: compile failure — `diarizeWithEmbeddings` doesn't exist; `output.speakers` doesn't exist on whatever it currently returns.

- [ ] **Step 4: Implement `diarizeWithEmbeddings`**

Edit `Sources/HarcSTT/Diarizer.swift`. Add the new struct + method, keeping the existing `diarize(audioPath:)` for now:

```swift
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's DiarizerManager. Separate from Transcriber because
/// the diarizer model loads independently — the Daemon pre-loads this in a
/// background task and degrades gracefully to empty speaker segments if load fails.
public actor Diarizer: DiarizeService {
    /// Returned by `diarizeWithEmbeddings` — both the segment timeline and
    /// the per-speaker centroid embeddings, in the wire-shape ready for
    /// `DiarizeResult`.
    public struct DiarizationOutput: Sendable, Equatable {
        public let segments: [SpeakerSegment]
        public let speakers: [SpeakerEmbeddingRow]
        public init(segments: [SpeakerSegment], speakers: [SpeakerEmbeddingRow]) {
            self.segments = segments
            self.speakers = speakers
        }
    }

    private var manager: DiarizerManager?
    private let audioConverter = AudioConverter()

    public init() {}

    public var isLoaded: Bool { manager != nil }

    public func loadModels() async throws {
        guard manager == nil else { return }
        let m = DiarizerManager(config: .default)
        let models = try await DiarizerModels.download()
        m.initialize(models: models)
        self.manager = m
    }

    public func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        try await diarizeWithEmbeddings(audioPath: audioPath).segments
    }

    public func diarizeWithEmbeddings(audioPath: String) async throws -> DiarizationOutput {
        guard let m = manager else { throw DaemonError.modelNotLoaded }

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        let result = try m.performCompleteDiarization(samples)

        // Map FluidAudio's String speakerIds to stable sequential Ints,
        // preserving insertion order. We need the mapping in two passes —
        // once for segments, once for the per-speaker embedding rollup.
        var speakerIndexByID: [String: Int] = [:]
        var segments: [SpeakerSegment] = []
        segments.reserveCapacity(result.segments.count)
        for seg in result.segments {
            let idx: Int
            if let existing = speakerIndexByID[seg.speakerId] {
                idx = existing
            } else {
                idx = speakerIndexByID.count
                speakerIndexByID[seg.speakerId] = idx
            }
            segments.append(SpeakerSegment(
                speaker: idx,
                startMs: Int(seg.startTimeSeconds * 1000),
                endMs: Int(seg.endTimeSeconds * 1000)
            ))
        }

        // Build per-speaker centroid + duration aggregates.
        // Preferred: FluidAudio's `speakerDatabase` is the authoritative
        // averaged centroid map keyed by speakerId. Fallback: weighted-
        // average the per-segment `embedding` vectors.
        let speakers = Self.buildSpeakerEmbeddingRows(
            segments: result.segments,
            speakerIndexByID: speakerIndexByID,
            speakerDatabase: result.speakerDatabase
        )

        return DiarizationOutput(segments: segments, speakers: speakers)
    }

    /// Pure helper for testability — does not touch FluidAudio state.
    static func buildSpeakerEmbeddingRows(
        segments: [TimedSpeakerSegment],
        speakerIndexByID: [String: Int],
        speakerDatabase: [String: [Float]]?
    ) -> [SpeakerEmbeddingRow] {
        // Aggregate totalMs and segmentCount per speaker.
        struct Agg {
            var totalMs: Int = 0
            var segmentCount: Int = 0
            var weightedSum: [Float] = []
        }
        var aggBySpeaker: [String: Agg] = [:]
        for seg in segments {
            var agg = aggBySpeaker[seg.speakerId] ?? Agg()
            let durMs = Int((seg.endTimeSeconds - seg.startTimeSeconds) * 1000)
            agg.totalMs += max(0, durMs)
            agg.segmentCount += 1
            // Build weighted sum vector for fallback path. Skip if seg
            // embedding is empty (defensive — FluidAudio sometimes returns
            // a zero-length placeholder).
            if !seg.embedding.isEmpty {
                if agg.weightedSum.isEmpty {
                    agg.weightedSum = [Float](repeating: 0, count: seg.embedding.count)
                }
                if agg.weightedSum.count == seg.embedding.count {
                    let w = Float(max(0, durMs))
                    for i in 0..<seg.embedding.count {
                        agg.weightedSum[i] += seg.embedding[i] * w
                    }
                }
            }
            aggBySpeaker[seg.speakerId] = agg
        }

        var rows: [SpeakerEmbeddingRow] = []
        rows.reserveCapacity(aggBySpeaker.count)
        for (speakerId, agg) in aggBySpeaker {
            guard let speakerIndex = speakerIndexByID[speakerId] else { continue }

            // Pick centroid: speakerDatabase if present, else fallback average.
            var vec: [Float]
            if let db = speakerDatabase, let centroid = db[speakerId], !centroid.isEmpty {
                vec = centroid
            } else if !agg.weightedSum.isEmpty, agg.totalMs > 0 {
                vec = agg.weightedSum
                let w = Float(agg.totalMs)
                for i in 0..<vec.count { vec[i] /= w }
            } else {
                continue   // No embedding source — skip the row.
            }

            l2Normalize(&vec)
            rows.append(SpeakerEmbeddingRow(
                speakerIndex: speakerIndex,
                vector: vec,
                totalMs: agg.totalMs,
                segmentCount: agg.segmentCount
            ))
        }
        // Sort by speakerIndex for deterministic ordering.
        rows.sort { $0.speakerIndex < $1.speakerIndex }
        return rows
    }
}

/// L2-normalize a vector in place. No-op if the norm is zero.
/// (Local copy here so HarcSTT doesn't need to depend on HarcVoiceprint.)
private func l2Normalize(_ v: inout [Float]) {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    let norm = sqrtf(sumSq)
    guard norm > 0 else { return }
    for i in 0..<v.count { v[i] /= norm }
}
```

- [ ] **Step 5: Add a focused unit test for `buildSpeakerEmbeddingRows` (the pure helper)**

Append to `Tests/HarcSTTTests/DiarizerTests.swift`:

```swift
@Test("buildSpeakerEmbeddingRows uses speakerDatabase when present")
func buildRowsPrefersSpeakerDatabase() {
    let dbVecA = [Float](repeating: 0.5, count: 256)
    let dbVecB: [Float] = {
        var v = [Float](repeating: 0, count: 256)
        v[0] = 1.0
        return v
    }()
    let segs = [
        TimedSpeakerSegment(
            speakerId: "A",
            embedding: [Float](repeating: 99, count: 256),  // ignored; DB wins
            startTimeSeconds: 0,
            endTimeSeconds: 2,
            qualityScore: 0
        ),
        TimedSpeakerSegment(
            speakerId: "B",
            embedding: [Float](repeating: 99, count: 256),
            startTimeSeconds: 2,
            endTimeSeconds: 5,
            qualityScore: 0
        ),
    ]
    let rows = Diarizer.buildSpeakerEmbeddingRows(
        segments: segs,
        speakerIndexByID: ["A": 0, "B": 1],
        speakerDatabase: ["A": dbVecA, "B": dbVecB]
    )
    #expect(rows.count == 2)
    #expect(rows[0].speakerIndex == 0)
    #expect(rows[0].totalMs == 2000)
    #expect(rows[0].segmentCount == 1)
    // dbVecA was uniform; L2-normalized uniform 256-vector has each component = 1/sqrt(256) = 0.0625.
    #expect(abs(rows[0].vector[0] - 0.0625) < 1e-4)
    // dbVecB had only index 0 set to 1; L2-normalized = same vector.
    #expect(abs(rows[1].vector[0] - 1) < 1e-4)
    #expect(abs(rows[1].vector[1] - 0) < 1e-4)
}

@Test("buildSpeakerEmbeddingRows falls back to weighted segment averaging")
func buildRowsFallsBackToAveraging() {
    let segA1: [Float] = [Float](repeating: 1.0, count: 256)
    let segA2: [Float] = [Float](repeating: 3.0, count: 256)
    let segs = [
        TimedSpeakerSegment(
            speakerId: "A",
            embedding: segA1,
            startTimeSeconds: 0,
            endTimeSeconds: 1,        // 1000ms weight
            qualityScore: 0
        ),
        TimedSpeakerSegment(
            speakerId: "A",
            embedding: segA2,
            startTimeSeconds: 1,
            endTimeSeconds: 4,        // 3000ms weight
            qualityScore: 0
        ),
    ]
    let rows = Diarizer.buildSpeakerEmbeddingRows(
        segments: segs,
        speakerIndexByID: ["A": 0],
        speakerDatabase: nil   // forces fallback
    )
    #expect(rows.count == 1)
    #expect(rows[0].totalMs == 4000)
    #expect(rows[0].segmentCount == 2)
    // Weighted mean: (1*1000 + 3*3000) / 4000 = 10000/4000 = 2.5. L2-normalized over 256
    // identical components: each = 1/sqrt(256) = 0.0625.
    #expect(abs(rows[0].vector[0] - 0.0625) < 1e-4)
}

@Test("buildSpeakerEmbeddingRows skips speakers with no usable embedding")
func buildRowsSkipsEmptyEmbeddings() {
    let segs = [
        TimedSpeakerSegment(
            speakerId: "A",
            embedding: [],   // unusable
            startTimeSeconds: 0,
            endTimeSeconds: 1,
            qualityScore: 0
        ),
    ]
    let rows = Diarizer.buildSpeakerEmbeddingRows(
        segments: segs,
        speakerIndexByID: ["A": 0],
        speakerDatabase: nil
    )
    #expect(rows.isEmpty)
}
```

- [ ] **Step 6: Run the unit tests for the helper**

```sh
swift test --filter HarcSTTTests.DiarizerTests.buildRowsPrefersSpeakerDatabase
swift test --filter HarcSTTTests.DiarizerTests.buildRowsFallsBackToAveraging
swift test --filter HarcSTTTests.DiarizerTests.buildRowsSkipsEmptyEmbeddings
```

Expected: all three helper-tests pass.

- [ ] **Step 7: Run the integration test**

```sh
swift test --filter HarcSTTTests.DiarizerTests.diarizeWithEmbeddingsReturnsVectors
```

Expected: PASS. (This test pulls down the FluidAudio diarizer model on first run — may take 30 s on a fresh machine.)

- [ ] **Step 8: Commit**

```sh
git add Sources/HarcSTT/Diarizer.swift Tests/HarcSTTTests/DiarizerTests.swift
git commit -m "$(cat <<'EOF'
feat(stt): Diarizer.diarizeWithEmbeddings — segments + WeSpeaker centroids

New method returns DiarizationOutput { segments, speakers } where speakers
contains one 256-dim L2-normalized SpeakerEmbeddingRow per clustered
speaker. Prefers FluidAudio's result.speakerDatabase when present;
falls back to weighted-by-duration averaging of per-segment embeddings.

Pure helper buildSpeakerEmbeddingRows is unit-tested independently.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: HarcSTT — `RequestHandler` honors `diarize: false` + handles `IPCRequest.diarize`

**Files:**
- Modify: `Sources/HarcSTT/RequestHandler.swift`
- Test: `Tests/HarcSTTTests/RequestHandlerTests.swift`

The handler currently always invokes the diarizer when one is present. We change it to:
1. On `transcribe`, only invoke the diarizer when `req.diarize == true`.
2. Add a new branch for `IPCRequest.diarize` that calls `diarizer.diarizeWithEmbeddings` and returns `IPCResponse.diarization(...)`.

`DiarizeService` protocol gains a new method.

- [ ] **Step 1: Write failing tests**

Append to `Tests/HarcSTTTests/RequestHandlerTests.swift`:

```swift
// Fake diarizer for tests below.
actor FakeDiarizer: DiarizeService {
    var diarizeCalls: [String] = []
    var diarizeWithEmbeddingsCalls: [String] = []

    var segmentsResult: [SpeakerSegment] = []
    var diarizationResult: Diarizer.DiarizationOutput = Diarizer.DiarizationOutput(
        segments: [],
        speakers: []
    )

    func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        diarizeCalls.append(audioPath)
        return segmentsResult
    }

    func diarizeWithEmbeddings(audioPath: String) async throws -> Diarizer.DiarizationOutput {
        diarizeWithEmbeddingsCalls.append(audioPath)
        return diarizationResult
    }

    var isLoaded: Bool { true }
}

@Test("transcribe with diarize=false skips the diarizer entirely")
func transcribeSkipsDiarizerWhenFlagFalse() async throws {
    let fake = FakeTranscriber()
    let fakeDi = FakeDiarizer()
    fakeDi.segmentsResult = [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)]
    let handler = RequestHandler(
        transcriber: fake, diarizer: fakeDi, version: "0.1.0", startedAt: Date()
    )
    let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", diarize: false))
    let resp = await handler.handle(req)
    if case .result(let r) = resp {
        #expect(r.speakers.isEmpty, "expected diarizer skipped, but got speakers: \(r.speakers)")
    } else {
        Issue.record("expected .result, got: \(resp)")
    }
    #expect(await fakeDi.diarizeCalls.isEmpty)
    #expect(await fakeDi.diarizeWithEmbeddingsCalls.isEmpty)
}

@Test("diarize request returns .diarization with embeddings")
func diarizeRequestReturnsEmbeddings() async throws {
    let fake = FakeTranscriber()
    let fakeDi = FakeDiarizer()
    fakeDi.diarizationResult = Diarizer.DiarizationOutput(
        segments: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 2000)],
        speakers: [SpeakerEmbeddingRow(
            speakerIndex: 0,
            vector: [Float](repeating: 0.0625, count: 256),
            totalMs: 2000,
            segmentCount: 1
        )]
    )
    let handler = RequestHandler(
        transcriber: fake, diarizer: fakeDi, version: "0.1.0", startedAt: Date()
    )
    let resp = await handler.handle(.diarize(DiarizeRequest(audioPath: "/tmp/d.wav")))
    if case .diarization(let d) = resp {
        #expect(d.segments.count == 1)
        #expect(d.speakers.count == 1)
        #expect(d.speakers[0].vector.count == 256)
    } else {
        Issue.record("expected .diarization, got: \(resp)")
    }
    #expect(await fakeDi.diarizeWithEmbeddingsCalls == ["/tmp/d.wav"])
}

@Test("diarize request without a diarizer returns .error")
func diarizeWithoutDiarizerErrors() async throws {
    let fake = FakeTranscriber()
    let handler = RequestHandler(
        transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
    )
    let resp = await handler.handle(.diarize(DiarizeRequest(audioPath: "/tmp/d.wav")))
    if case .error(let e) = resp {
        #expect(e.code == "diarizer_unavailable")
    } else {
        Issue.record("expected .error, got: \(resp)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```sh
swift test --filter HarcSTTTests.RequestHandlerTests
```

Expected: compile failures + behavior failures (no `.diarize` handler; diarizer is invoked even when `diarize: false`; `DiarizeService` doesn't have `diarizeWithEmbeddings`).

- [ ] **Step 3: Update `DiarizeService` protocol + RequestHandler**

Edit `Sources/HarcSTT/RequestHandler.swift`. Replace its full content with:

```swift
import Foundation
import HarcCore

/// Minimal protocol so RequestHandler can be unit-tested against fakes.
public protocol TranscribeService: Sendable {
    func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult
    var isLoaded: Bool { get async }
}

extension Transcriber: TranscribeService {}

public protocol DiarizeService: Sendable {
    func diarize(audioPath: String) async throws -> [SpeakerSegment]
    func diarizeWithEmbeddings(audioPath: String) async throws -> Diarizer.DiarizationOutput
    var isLoaded: Bool { get async }
}

public struct RequestHandler: Sendable {
    private let transcriber: any TranscribeService
    private let diarizer: (any DiarizeService)?
    private let version: String
    private let startedAt: Date

    public init(
        transcriber: any TranscribeService,
        diarizer: (any DiarizeService)?,
        version: String,
        startedAt: Date
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.version = version
        self.startedAt = startedAt
    }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request {
        case .status:
            return .status(DaemonStatus(
                version: version,
                modelLoaded: await transcriber.isLoaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .shutdown:
            return .status(DaemonStatus(
                version: version,
                modelLoaded: await transcriber.isLoaded,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            ))

        case .transcribe(let req):
            do {
                var result = try await transcriber.transcribe(audioPath: req.audioPath, vad: req.vad)
                if req.diarize, let diarizer {
                    do {
                        let segs = try await diarizer.diarize(audioPath: req.audioPath)
                        result.speakers = segs
                    } catch {
                        // Diarization is best-effort during chunked transcribe;
                        // log but return text + words intact.
                        FileHandle.standardError.write(Data(
                            "harc-stt: diarize failed (transcribe path): \(error.localizedDescription)\n".utf8
                        ))
                    }
                }
                return .result(result)
            } catch {
                return .error(IPCError(
                    code: "transcribe_failed",
                    message: error.localizedDescription
                ))
            }

        case .diarize(let req):
            guard let diarizer else {
                return .error(IPCError(
                    code: "diarizer_unavailable",
                    message: "Diarizer model not loaded"
                ))
            }
            let started = Date()
            do {
                let output = try await diarizer.diarizeWithEmbeddings(audioPath: req.audioPath)
                let processingMs = Int(Date().timeIntervalSince(started) * 1000)
                return .diarization(DiarizeResult(
                    segments: output.segments,
                    speakers: output.speakers,
                    processingMs: processingMs
                ))
            } catch {
                return .error(IPCError(
                    code: "diarize_failed",
                    message: error.localizedDescription
                ))
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```sh
swift test --filter HarcSTTTests.RequestHandlerTests
```

Expected: all RequestHandler tests pass, including the three new ones.

- [ ] **Step 5: Commit**

```sh
git add Sources/HarcSTT/RequestHandler.swift Tests/HarcSTTTests/RequestHandlerTests.swift
git commit -m "$(cat <<'EOF'
feat(stt): RequestHandler — diarize verb + diarize=false short-circuit

New IPCRequest.diarize handler calls Diarizer.diarizeWithEmbeddings and
returns IPCResponse.diarization with segments + per-speaker embeddings.
Returns 'diarizer_unavailable' error when no diarizer is wired.

transcribe handler now skips the diarizer entirely when req.diarize=false.
Saves daemon work for the per-chunk path which no longer needs diarization.

DiarizeService protocol gains diarizeWithEmbeddings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase C — Client-side IPC + chunked transcriber

After this phase the app sends `transcribe(diarize: false)` per chunk and a single `diarize(...)` call after stop, returning a SessionTranscript whose speakers come from the full-WAV diarization pass.

---

### Task 7: HarcClient — `HarcSTTClient.diarize(audioPath:)` method

**Files:**
- Modify: `Sources/HarcClient/HarcSTTClient.swift`
- Test: `Tests/HarcClientTests/HarcSTTClientTests.swift`

- [ ] **Step 1: Read the existing test file to learn the socketpair test pattern**

```sh
cat Tests/HarcClientTests/HarcSTTClientTests.swift | head -80
```

The existing tests use `socketpair()` to get a connected pair, then drive the daemon side from a `Task` and the client side via `HarcSTTClient(connectedFd:)`.

- [ ] **Step 2: Write failing test for `diarize` method**

Append to `Tests/HarcClientTests/HarcSTTClientTests.swift`:

```swift
@Test("diarize sends DiarizeRequest and returns DiarizeResult")
func diarizeRoundTrip() async throws {
    var fds: [Int32] = [-1, -1]
    let pair = fds.withUnsafeMutableBufferPointer {
        socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
    }
    #expect(pair == 0)
    let serverFd = fds[0]
    let clientFd = fds[1]

    // Server side — read request, write response.
    let serverTask = Task.detached {
        var buf = Data()
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { scratch.deallocate() }
        while !buf.contains(0x0A) {
            let n = read(serverFd, scratch, 4096)
            if n <= 0 { break }
            buf.append(scratch, count: n)
        }

        let nl = buf.firstIndex(of: 0x0A) ?? buf.endIndex
        let req = try JSONDecoder().decode(IPCRequest.self, from: buf.prefix(upTo: nl))
        if case .diarize(let dreq) = req {
            #expect(dreq.audioPath == "/tmp/dx.wav")
        } else {
            Issue.record("expected .diarize, got \(req)")
        }

        let resp = IPCResponse.diarization(DiarizeResult(
            segments: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1500)],
            speakers: [SpeakerEmbeddingRow(
                speakerIndex: 0,
                vector: [Float](repeating: 0.0625, count: 256),
                totalMs: 1500,
                segmentCount: 1
            )],
            processingMs: 42
        ))
        var data = try JSONEncoder().encode(resp)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(serverFd, $0.baseAddress, data.count) }
        Darwin.close(serverFd)
    }

    let client = HarcSTTClient(connectedFd: clientFd)
    let result = try await client.diarize(audioPath: "/tmp/dx.wav")
    #expect(result.segments.count == 1)
    #expect(result.speakers.count == 1)
    #expect(result.speakers[0].vector.count == 256)
    #expect(result.processingMs == 42)
    _ = await serverTask.value
    Darwin.close(clientFd)
}
```

- [ ] **Step 3: Run the test to verify it fails**

```sh
swift test --filter HarcClientTests.HarcSTTClientTests.diarizeRoundTrip
```

Expected: compile failure — `client.diarize(audioPath:)` doesn't exist.

- [ ] **Step 4: Add the `diarize` method**

Edit `Sources/HarcClient/HarcSTTClient.swift`. After the existing `transcribe` method, before `shutdown`, insert:

```swift
    public func diarize(audioPath: String) async throws -> DiarizeResult {
        let request = IPCRequest.diarize(DiarizeRequest(audioPath: audioPath))
        let response = try await roundTrip(request)
        switch response {
        case .diarization(let d): return d
        case .error(let e): throw ClientError.transcribeFailed(code: e.code, message: e.message)
        default: throw ClientError.ipcDecodeFailed("unexpected response: \(response)")
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

```sh
swift test --filter HarcClientTests.HarcSTTClientTests.diarizeRoundTrip
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcClient/HarcSTTClient.swift Tests/HarcClientTests/HarcSTTClientTests.swift
git commit -m "$(cat <<'EOF'
feat(client): HarcSTTClient.diarize(audioPath:) round-trip

Mirrors transcribe's connect/send/recv/close pattern. Sends
IPCRequest.diarize, expects IPCResponse.diarization, surfaces
.error responses as ClientError.transcribeFailed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: HarcClient — `ChunkedTranscriber` per-chunk `diarize: false` + post-finalize diarize call

**Files:**
- Modify: `Sources/HarcClient/ChunkedTranscriber.swift`
- Test: `Tests/HarcClientTests/ChunkedTranscriberTests.swift`

The transcriber's `finalize` method changes its return type from `SessionTranscript` to `(SessionTranscript, [SpeakerEmbeddingRow])`. Per-chunk transcribe calls now always send `diarize: false`. We add a `DiarizingClient` protocol so the new diarize call is testable through a fake.

- [ ] **Step 1: Add `DiarizingClient` protocol in ChunkedTranscriber.swift**

Edit `Sources/HarcClient/ChunkedTranscriber.swift`. Replace the entire file with:

```swift
import Foundation
import HarcCore

/// Protocol boundary for testing — any client that can transcribe a WAV path.
public protocol TranscribingClient: Sendable {
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult
}

/// Protocol boundary for testing — any client that can run a full-WAV
/// diarization pass at end-of-recording.
public protocol DiarizingClient: Sendable {
    func diarize(audioPath: String) async throws -> DiarizeResult
}

extension HarcSTTClient: TranscribingClient {}
extension HarcSTTClient: DiarizingClient {}

/// Result bundle returned from `finalize`. The caller persists the embeddings
/// alongside the recording row in a single transactional ingest.
public struct ChunkedTranscriberFinalize: Sendable {
    public let transcript: SessionTranscript
    /// Per-speaker WeSpeaker centroid rows from the post-stop diarize pass.
    /// Empty when diarization failed or returned nothing.
    public let speakerEmbeddings: [SpeakerEmbeddingRow]
    /// Set when the diarize pass failed; the transcript's text + words are
    /// still complete. UI layers surface a retry affordance from this.
    public let diarizationError: String?

    public init(
        transcript: SessionTranscript,
        speakerEmbeddings: [SpeakerEmbeddingRow],
        diarizationError: String?
    ) {
        self.transcript = transcript
        self.speakerEmbeddings = speakerEmbeddings
        self.diarizationError = diarizationError
    }
}

/// Drives a WAVChunker, dispatches each chunk to a TranscribingClient,
/// assembles a session transcript. After tail flush, calls `diarize` once
/// on the full WAV via the DiarizingClient and uses its segments as the
/// authoritative speaker labels for the recording.
public actor ChunkedTranscriber {
    private let client: any TranscribingClient
    private let diarizer: (any DiarizingClient)?
    private let vadEnabled: Bool
    private let chunkDurationSeconds: Double
    private let pollIntervalSeconds: Double
    private let vocabulary: Vocabulary

    nonisolated(unsafe) private let assembler = TranscriptAssembler()
    private var chunker: WAVChunker?
    private var audioURL: URL?
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    public let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    public init(
        client: any TranscribingClient,
        diarizer: (any DiarizingClient)? = nil,
        vadEnabled: Bool = true,
        chunkDurationSeconds: Double = 60.0,
        pollIntervalSeconds: Double = 2.0,
        vocabulary: Vocabulary = .empty
    ) {
        self.client = client
        self.diarizer = diarizer
        self.vadEnabled = vadEnabled
        self.chunkDurationSeconds = chunkDurationSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.vocabulary = vocabulary
        let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
        self.updates = stream
        self.updatesContinuation = cont
    }

    public func start(audioURL: URL) {
        self.audioURL = audioURL
        self.chunker = WAVChunker(audioURL: audioURL, chunkDurationSeconds: chunkDurationSeconds)
        self.pumpTask = Task.detached { [self] in await self.pump() }
    }

    /// Stops polling, processes any remaining tail chunk, runs the full-WAV
    /// diarize pass, and returns the assembled transcript + embeddings.
    public func finalize(startedAt: Date, endedAt: Date) async throws -> ChunkedTranscriberFinalize {
        stopped = true
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        if let chunker {
            do {
                if let tail = try await chunker.flush() {
                    try await processChunk(tail)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-client: tail chunk failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        updatesContinuation.finish()

        var assembled = assembler.finalize(
            startedAt: startedAt,
            endedAt: endedAt,
            audioPath: audioURL?.path ?? ""
        )
        assembled.joinedText = VocabularyReplacer.apply(assembled.joinedText, using: vocabulary)

        // Full-WAV diarization pass. On failure, return text + words and
        // surface the error string so UI layers can offer a retry.
        var speakerEmbeddings: [SpeakerEmbeddingRow] = []
        var diarizationError: String?
        if let diarizer, let url = audioURL {
            do {
                let result = try await diarizer.diarize(audioPath: url.path)
                assembled.speakers = result.segments
                speakerEmbeddings = result.speakers
            } catch {
                diarizationError = error.localizedDescription
                FileHandle.standardError.write(Data(
                    "harc-client: post-stop diarize failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return ChunkedTranscriberFinalize(
            transcript: assembled,
            speakerEmbeddings: speakerEmbeddings,
            diarizationError: diarizationError
        )
    }

    private func pump() async {
        guard let chunker else { return }
        while !Task.isCancelled, !stopped {
            do {
                if let chunk = try await chunker.nextChunk() {
                    try await processChunk(chunk)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-client: chunk transcription failed: \(error.localizedDescription)\n".utf8
                ))
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func processChunk(_ chunk: WAVChunker.Chunk) async throws {
        defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
        // Per-chunk diarization is OFF — labels come from the post-stop
        // full-WAV diarize call in `finalize`.
        let result = try await client.transcribe(audioPath: chunk.audioURL.path, diarize: false, vad: vadEnabled)
        let cleanedText = VocabularyReplacer.apply(result.text, using: vocabulary)
        let cr = ChunkResult(
            startMs: chunk.startMs,
            endMs: chunk.endMs,
            text: cleanedText,
            words: result.words,
            speakers: [],   // Per-chunk diarization is intentionally empty.
            processingMs: result.processingMs
        )
        assembler.add(cr)
        let index = assembler.currentJoinedText.isEmpty ? 0 : (assembler.currentJoinedText.split(separator: " ").count)
        updatesContinuation.yield(TranscriptUpdate(
            chunkIndex: index,
            joinedTextSoFar: assembler.currentJoinedText
        ))
    }
}
```

- [ ] **Step 2: Update existing tests for the new return type**

Edit `Tests/HarcClientTests/ChunkedTranscriberTests.swift`. Existing tests call `let transcript = try await transcriber.finalize(...)`. Change every such call to:

```swift
let result = try await transcriber.finalize(startedAt: start, endedAt: end)
let transcript = result.transcript
```

(Use search-and-replace within the file. Existing tests don't pass a `diarizer:` so it defaults to nil, exercising the no-diarizer path.)

Also update the `FakeClient` in the existing test file's `transcribe` method signature: it should still accept `diarize: Bool` (the wire signature). What changed is the *value* — every per-chunk call now arrives with `diarize: false`. The existing assertion `transcribe forwards diarize=...` no longer matches reality, so those test lines (if any) need updating to expect `false`. Search for any test asserting `diarize` was forwarded as `true` and update to expect `false`.

To find them:

```sh
grep -n "diarize" Tests/HarcClientTests/ChunkedTranscriberTests.swift
```

Update any assertions that expected `diarize == true` to instead expect `diarize == false`. If a test was specifically about the deprecated `init(diarize: true/false)` API, delete it — the parameter is gone.

- [ ] **Step 3: Add new test — `finalize` calls diarize and uses its segments**

Append to `Tests/HarcClientTests/ChunkedTranscriberTests.swift`:

```swift
actor FakeDiarizingClient: DiarizingClient {
    var calls: [String] = []
    var result: DiarizeResult = DiarizeResult(segments: [], speakers: [], processingMs: 0)
    var shouldThrow: Error?

    init(result: DiarizeResult = DiarizeResult(segments: [], speakers: [], processingMs: 0)) {
        self.result = result
    }

    func diarize(audioPath: String) async throws -> DiarizeResult {
        calls.append(audioPath)
        if let err = shouldThrow { throw err }
        return result
    }
}

@Test("finalize calls diarize once on the full WAV and uses its segments")
func finalizeRunsFullWAVDiarize() async throws {
    let url = tempWAVPath()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeSineWAV(to: url, seconds: 2.0)

    let fake = FakeClient(results: [
        TranscribeResult(text: "hi", words: [Word(text: "hi", startMs: 0, endMs: 200)],
                         speakers: [], processingMs: 1),
        TranscribeResult(text: "bye", words: [Word(text: "bye", startMs: 0, endMs: 200)],
                         speakers: [], processingMs: 1),
    ])
    let fakeDi = FakeDiarizingClient(result: DiarizeResult(
        segments: [
            SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
            SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2000),
        ],
        speakers: [
            SpeakerEmbeddingRow(
                speakerIndex: 0,
                vector: [Float](repeating: 0.0625, count: 256),
                totalMs: 1000,
                segmentCount: 1
            ),
            SpeakerEmbeddingRow(
                speakerIndex: 1,
                vector: [Float](repeating: 0.0625, count: 256),
                totalMs: 1000,
                segmentCount: 1
            ),
        ],
        processingMs: 50
    ))

    let transcriber = ChunkedTranscriber(
        client: fake,
        diarizer: fakeDi,
        chunkDurationSeconds: 1.0,
        pollIntervalSeconds: 0.05
    )
    await transcriber.start(audioURL: url)
    try await Task.sleep(nanoseconds: 400_000_000)

    let result = try await transcriber.finalize(
        startedAt: Date().addingTimeInterval(-3),
        endedAt: Date()
    )

    #expect(await fakeDi.calls == [url.path])
    #expect(result.transcript.speakers.count == 2)
    #expect(result.speakerEmbeddings.count == 2)
    #expect(result.diarizationError == nil)
}

@Test("finalize tolerates diarize errors — transcript still returned")
func finalizeToleratesDiarizeError() async throws {
    let url = tempWAVPath()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeSineWAV(to: url, seconds: 1.5)

    let fake = FakeClient(results: [
        TranscribeResult(text: "hi", words: [Word(text: "hi", startMs: 0, endMs: 200)],
                         speakers: [], processingMs: 1),
    ])
    let fakeDi = FakeDiarizingClient()
    await fakeDi.setShouldThrow(NSError(
        domain: "test", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "diarize blew up"]
    ))

    let transcriber = ChunkedTranscriber(
        client: fake,
        diarizer: fakeDi,
        chunkDurationSeconds: 1.0,
        pollIntervalSeconds: 0.05
    )
    await transcriber.start(audioURL: url)
    try await Task.sleep(nanoseconds: 400_000_000)

    let result = try await transcriber.finalize(
        startedAt: Date().addingTimeInterval(-3),
        endedAt: Date()
    )

    #expect(result.transcript.joinedText.contains("hi"))
    #expect(result.transcript.speakers.isEmpty)
    #expect(result.speakerEmbeddings.isEmpty)
    #expect(result.diarizationError == "diarize blew up")
}

@Test("per-chunk transcribe always sends diarize=false")
func perChunkSendsDiarizeFalse() async throws {
    let url = tempWAVPath()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeSineWAV(to: url, seconds: 1.5)

    let fake = FakeClient(results: [
        TranscribeResult(text: "hi", words: [], speakers: [], processingMs: 1),
    ])
    let transcriber = ChunkedTranscriber(
        client: fake,
        chunkDurationSeconds: 1.0,
        pollIntervalSeconds: 0.05
    )
    await transcriber.start(audioURL: url)
    try await Task.sleep(nanoseconds: 400_000_000)
    _ = try await transcriber.finalize(
        startedAt: Date().addingTimeInterval(-3), endedAt: Date()
    )

    #expect(await fake.calls.allSatisfy { $0.diarize == false })
}
```

You'll need to add a `setShouldThrow` setter on `FakeDiarizingClient` so the test can mutate it through the actor isolation. Add to the `FakeDiarizingClient` declaration:

```swift
    func setShouldThrow(_ err: Error?) { self.shouldThrow = err }
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
swift test --filter HarcClientTests.ChunkedTranscriberTests
```

Expected: all chunked-transcriber tests pass, including the three new ones.

- [ ] **Step 5: Run the full HarcClient test target**

```sh
swift test --filter HarcClientTests
```

Expected: PASS. Any callers of the old single-return-value `finalize()` (e.g., `EndToEndTests`) need their unwrap updated to `result.transcript`.

If `EndToEndTests` or `TranscriptWriterTests` break, update them inline using the same `let result = try await ...; let transcript = result.transcript` pattern. Keep the change minimal — those tests don't need to assert on the embeddings.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcClient/ChunkedTranscriber.swift Tests/HarcClientTests/
git commit -m "$(cat <<'EOF'
feat(client): per-chunk diarize=false, full-WAV diarize at finalize

ChunkedTranscriber now always sends transcribe(diarize: false) per chunk
and runs a single client.diarize(audioPath:) on the final WAV in
finalize(). The full-WAV pass is the source of truth for SpeakerSegment
labels — solves the per-chunk speaker-label flip bug.

finalize() now returns ChunkedTranscriberFinalize {transcript,
speakerEmbeddings, diarizationError}. On diarize failure, transcript
text+words are intact and the error message is surfaced for UI retry.

New DiarizingClient protocol gives tests a fake-able seam.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase D — HarcUI changes

These tasks update the cosine threshold + filter, flip the default pref, introduce the `RecordingPostProcessingState`, and wire it through the popover and detail view.

---

### Task 9: HarcUI — `SpeakerReIDService` threshold + `embedderKind` filter

**Files:**
- Modify: `Sources/HarcUI/SpeakerReIDService.swift`
- Test: `Tests/HarcUITests/SpeakerReIDServiceTests.swift` (or wherever existing tests live — check first with `ls Tests/HarcUITests/ | grep -i ReID`)

- [ ] **Step 1: Read the current `SpeakerReIDService.swift` to confirm the threshold line and store-call signature**

```sh
cat Sources/HarcUI/SpeakerReIDService.swift
```

Locate: (a) the cosine threshold constant (currently `0.62`); (b) the store call in `suggestMatches` (currently calls `store.allSpeakerEmbeddings(excludingRecording:)` without `embedderKind:`); (c) the import of `HarcVoiceprint` (we'll use `EmbedderKind.wespeakerV2`).

- [ ] **Step 2: Write failing test for the new threshold**

Find the existing service tests — `grep -rn "SpeakerReIDService" Tests/`. Append to that file (or create `Tests/HarcUITests/SpeakerReIDServiceTests.swift` if none):

```swift
@Test("default cosine threshold is 0.65 (WeSpeaker-tuned)")
func defaultThresholdIs065() {
    #expect(SpeakerReIDService.defaultThreshold == 0.65)
}

@Test("suggestMatches filters by embedderKind when querying the store")
func suggestMatchesFiltersByEmbedderKind() async throws {
    let store = try await RecordingStore.inMemory()
    // Two recordings with different embedder kinds at high mutual similarity.
    let recA = try await store.upsert(Recording(wavPath: "/tmp/a.wav", startedAt: Date()))
    let recB = try await store.upsert(Recording(wavPath: "/tmp/b.wav", startedAt: Date()))
    let recC = try await store.upsert(Recording(wavPath: "/tmp/c.wav", startedAt: Date()))

    let v: [Float] = {
        var x = [Float](repeating: 0, count: 256)
        x[0] = 1
        return x
    }()
    let blob = EmbeddingBlob.encode(v)

    try await store.upsertSpeakerEmbeddings(
        recordingID: recA.id!,
        rows: [RecordingStore.SpeakerEmbeddingRow(
            recordingID: recA.id!, speakerIndex: 0,
            embedding: blob, segmentCount: 1, totalMs: 6000,
            embedderKind: "ecapa_v1"   // wrong kind — should be filtered out
        )]
    )
    try await store.upsertSpeakerEmbeddings(
        recordingID: recB.id!,
        rows: [RecordingStore.SpeakerEmbeddingRow(
            recordingID: recB.id!, speakerIndex: 0,
            embedding: blob, segmentCount: 1, totalMs: 6000,
            embedderKind: EmbedderKind.wespeakerV2
        )]
    )

    let resolver = StoreSpeakerNameResolver(store: store)
    let service = SpeakerReIDService(store: store, resolver: resolver)
    let matches = try await service.suggestMatches(
        for: v,
        excludingRecording: recC.id!
    )

    #expect(matches.count == 1, "expected only the wespeaker_v2 row to match; got \(matches.count)")
    #expect(matches[0].recordingID == recB.id!)
}
```

(Replace the `service.suggestMatches(...)` signature/argument names with whatever the existing service uses if these don't match — the goal is that the test asserts only `wespeaker_v2`-tagged rows are visible.)

- [ ] **Step 3: Run the tests to verify they fail**

```sh
swift test --filter HarcUITests.SpeakerReIDServiceTests
```

Expected: failures (threshold is 0.62; filter doesn't apply embedder kind).

- [ ] **Step 4: Update the service**

Edit `Sources/HarcUI/SpeakerReIDService.swift`:

1. Change the threshold constant from `0.62` to `0.65`. Expose as `public static let defaultThreshold: Float = 0.65` if it isn't already public.
2. In `suggestMatches`, change the store call from `store.allSpeakerEmbeddings(excludingRecording: ...)` to:

   ```swift
   try await store.allSpeakerEmbeddings(
       excludingRecording: excludingRecording,
       embedderKind: EmbedderKind.wespeakerV2
   )
   ```

3. Make sure `import HarcVoiceprint` is present (it likely already is — `EmbeddingBlob` and `CosineSimilarity` come from there).

- [ ] **Step 5: Run the tests to verify they pass**

```sh
swift test --filter HarcUITests.SpeakerReIDServiceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcUI/SpeakerReIDService.swift Tests/HarcUITests/SpeakerReIDServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): SpeakerReIDService — 0.65 threshold + embedder-kind filter

Default threshold moves from 0.62 (ECAPA-tuned) to 0.65 (WeSpeaker-tuned).
suggestMatches now filters store rows to embedderKind = wespeaker_v2 so
stale or differently-versioned vectors are silently invisible to
cross-recording cosine search.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: HarcUI — `HarcPreferences.speakerReIDEnabled` default flips to true

**Files:**
- Modify: `Sources/HarcUI/HarcPreferences.swift`
- Test: `Tests/HarcUITests/HarcPreferencesTests.swift` (search first; create only if needed)

- [ ] **Step 1: Find existing preferences tests**

```sh
ls Tests/HarcUITests/ | grep -i Preference
grep -rn "speakerReIDEnabled" Tests/ 2>/dev/null
```

- [ ] **Step 2: Write failing test for the default value**

Append to whichever HarcPreferences test file exists (create `Tests/HarcUITests/HarcPreferencesDefaultsTests.swift` if none):

```swift
import Testing
import Foundation
@testable import HarcUI

@Suite("HarcPreferences defaults")
struct HarcPreferencesDefaultsTests {
    @Test("speakerReIDEnabled defaults to true on a fresh install")
    func speakerReIDEnabledDefaultIsTrue() {
        let suite = "harc.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Don't set anything — fresh install.
        let prefs = HarcPreferences(defaults: defaults)
        #expect(prefs.speakerReIDEnabled == true)
    }

    @Test("speakerReIDAutoApply defaults to false")
    func speakerReIDAutoApplyDefaultIsFalse() {
        let suite = "harc.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = HarcPreferences(defaults: defaults)
        #expect(prefs.speakerReIDAutoApply == false)
    }

    @Test("user-set false value is preserved across construction")
    func userSetFalseRetained() {
        let suite = "harc.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "harc.speakerReIDEnabled")

        let prefs = HarcPreferences(defaults: defaults)
        #expect(prefs.speakerReIDEnabled == false)
    }
}
```

(If `HarcPreferences.init(defaults:)` doesn't currently take a `UserDefaults` parameter, update the call to whatever the existing test pattern uses. If the type is `@MainActor`, prefix the tests with `@MainActor`.)

- [ ] **Step 3: Run the tests to verify they fail**

```sh
swift test --filter HarcUITests.HarcPreferencesDefaultsTests
```

Expected: the "default true" test fails (current default is false).

- [ ] **Step 4: Flip the default**

Edit `Sources/HarcUI/HarcPreferences.swift`. Find the line:

```swift
self.speakerReIDEnabled = defaults.object(forKey: Key.speakerReIDEnabled) as? Bool ?? false
```

Change the trailing `?? false` to `?? true`:

```swift
self.speakerReIDEnabled = defaults.object(forKey: Key.speakerReIDEnabled) as? Bool ?? true
```

Leave `speakerReIDAutoApply` as `?? false` (unchanged).

- [ ] **Step 5: Run the tests to verify they pass**

```sh
swift test --filter HarcUITests.HarcPreferencesDefaultsTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcUI/HarcPreferences.swift Tests/HarcUITests/HarcPreferencesDefaultsTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): speakerReIDEnabled defaults to true (real embedder shipped)

The placeholder StubSpeakerEmbedder kept this default false. With
WeSpeaker v2 supplying a real voice fingerprint, cross-recording
suggestions are useful out of the box. User-set false values are
preserved unchanged.

speakerReIDAutoApply stays false — suggestions remain one click,
never silent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: HarcUI — `RecordingPostProcessingState` ObservableObject

**Files:**
- Create: `Sources/HarcUI/RecordingPostProcessingState.swift`
- Test: `Tests/HarcUITests/RecordingPostProcessingStateTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/HarcUITests/RecordingPostProcessingStateTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcUI

@Suite("RecordingPostProcessingState")
@MainActor
struct RecordingPostProcessingStateTests {
    @Test("initial state has no current recording")
    func initialIsIdle() {
        let s = RecordingPostProcessingState()
        #expect(s.current == nil)
    }

    @Test("begin sets phase to .identifying for the right ID")
    func beginSetsIdentifying() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 42)
        if case .identifying = s.current?.phase {
            #expect(s.current?.recordingID == 42)
        } else {
            Issue.record("expected .identifying, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("succeed transitions to .done with speakerCount")
    func succeedTransitionsToDone() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 7)
        s.succeed(recordingID: 7, speakerCount: 3)
        if case .done(let n) = s.current?.phase {
            #expect(n == 3)
            #expect(s.current?.recordingID == 7)
        } else {
            Issue.record("expected .done(3), got \(String(describing: s.current?.phase))")
        }
    }

    @Test("succeed for a different recording is a no-op")
    func succeedForOtherIDIgnored() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 1)
        s.succeed(recordingID: 99, speakerCount: 5)
        if case .identifying = s.current?.phase {
            #expect(s.current?.recordingID == 1)
        } else {
            Issue.record("expected unchanged .identifying, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("fail transitions to .failed with message")
    func failTransitionsToFailed() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 9)
        s.fail(recordingID: 9, message: "model crashed")
        if case .failed(let msg) = s.current?.phase {
            #expect(msg == "model crashed")
        } else {
            Issue.record("expected .failed, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("clear nils current when matched")
    func clearNilsCurrent() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 11)
        s.clear(recordingID: 11)
        #expect(s.current == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```sh
swift test --filter HarcUITests.RecordingPostProcessingStateTests
```

Expected: compile failure — `RecordingPostProcessingState` doesn't exist.

- [ ] **Step 3: Create the type**

Create `Sources/HarcUI/RecordingPostProcessingState.swift`:

```swift
import Foundation
import Combine

/// Phase a recording moves through after the user hits stop:
///   .idle               (initial; not set on `current`)
///   .identifying        (full-WAV diarization in flight)
///   .done(speakerCount) (labels written; auto-collapses in UI ~1.5 s)
///   .failed(message)    (diarize failed; UI offers retry)
public enum DiarizationPhase: Equatable, Sendable {
    case idle
    case identifying(startedAt: Date)
    case done(speakerCount: Int)
    case failed(message: String)
}

/// MainActor-bound observable; only one recording is ever post-processing
/// at a time so a single optional pair `(recordingID, phase)` suffices.
///
/// Mutators are gated on the recording ID — a stale `succeed(recordingID:)`
/// for a recording that's already been superseded is a no-op. This avoids
/// race conditions where the user starts a new recording before the prior
/// one's post-stop diarize call returns.
@MainActor
public final class RecordingPostProcessingState: ObservableObject {
    @Published public private(set) var current: Entry?

    public struct Entry: Equatable, Sendable {
        public let recordingID: Int64
        public let phase: DiarizationPhase
    }

    public init() {}

    public func begin(recordingID: Int64) {
        current = Entry(
            recordingID: recordingID,
            phase: .identifying(startedAt: Date())
        )
    }

    public func succeed(recordingID: Int64, speakerCount: Int) {
        guard current?.recordingID == recordingID else { return }
        current = Entry(recordingID: recordingID, phase: .done(speakerCount: speakerCount))
    }

    public func fail(recordingID: Int64, message: String) {
        guard current?.recordingID == recordingID else { return }
        current = Entry(recordingID: recordingID, phase: .failed(message: message))
    }

    public func clear(recordingID: Int64) {
        guard current?.recordingID == recordingID else { return }
        current = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
swift test --filter HarcUITests.RecordingPostProcessingStateTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add Sources/HarcUI/RecordingPostProcessingState.swift Tests/HarcUITests/RecordingPostProcessingStateTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): RecordingPostProcessingState — drives post-stop diarize UX

@MainActor ObservableObject tracking the .idle/.identifying/.done/.failed
phase of the currently-post-processing recording. Mutators are gated on
recording ID so a stale succeed/fail call (e.g., from a prior recording
whose diarize finally returned after the user started a new one) is a
no-op. Only one recording is ever post-processing at a time, so a single
optional Entry pair suffices.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: HarcUI — Popover post-stop tray binds to `RecordingPostProcessingState`

**Files:**
- Modify: `Sources/HarcUI/PopoverRootView.swift` (or wherever the post-stop tray view is rendered)
- Test: this is a SwiftUI view change. Logic is mostly state-driven; manually verified in QA Task 16.

- [ ] **Step 1: Locate the post-stop tray view**

```sh
grep -rln "post-stop\|stoppedRecording\|justStopped\|RecordingFinished\|copyForPrompt\|Copy plain text\|Copy for prompt" Sources/HarcUI/
```

You should find the view (or section of `PopoverRootView`) that renders Copy plain text / Copy for prompt buttons after a recording finishes. If the post-stop tray is its own view, work in that file; otherwise add the new state row inline within `PopoverRootView`.

- [ ] **Step 2: Inject `RecordingPostProcessingState` as `@EnvironmentObject`**

Add to the relevant view:

```swift
@EnvironmentObject private var postProcessing: RecordingPostProcessingState
```

You'll also need to inject this on the `PopoverRootView`'s call site. Defer that to Task 14 (AppDelegate wiring) — flag with a `// TODO Task 14: env-inject postProcessing` comment for now if needed.

- [ ] **Step 3: Render the inline status row**

Within the post-stop tray's `body`, insert a status row above the action buttons:

```swift
@ViewBuilder
private var diarizationStatusRow: some View {
    if let entry = postProcessing.current,
       entry.recordingID == currentRecordingID  // however this view tracks it
    {
        switch entry.phase {
        case .idle:
            EmptyView()
        case .identifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Identifying speakers…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.bottom, 4)
        case .done(let n):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(n) speaker\(n == 1 ? "" : "s") identified")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.bottom, 4)
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't identify speakers")
                    .font(.caption)
                Button("Retry") {
                    onRetryDiarize()    // closure threaded down from AppDelegate
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .help(msg)
            .padding(.bottom, 4)
        }
    }
}
```

Place `diarizationStatusRow` immediately above the existing Copy/Open/Paste buttons.

- [ ] **Step 4: Disable "Copy for prompt" during `.identifying`**

Find the Copy-for-prompt button and add a `.disabled(...)` modifier:

```swift
Button("Copy for prompt") { ... }
    .disabled(isIdentifyingSpeakers)
```

Where `isIdentifyingSpeakers` is a computed property:

```swift
private var isIdentifyingSpeakers: Bool {
    guard let entry = postProcessing.current,
          entry.recordingID == currentRecordingID else { return false }
    if case .identifying = entry.phase { return true }
    return false
}
```

Leave Copy-plain-text and Open enabled in all phases.

- [ ] **Step 5: Auto-collapse `.done` after ~1.5 s**

In the same view, add a `.onChange(of: postProcessing.current)` that schedules a `clear` call:

```swift
.onChange(of: postProcessing.current) { _, newValue in
    guard let entry = newValue,
          entry.recordingID == currentRecordingID,
          case .done = entry.phase else { return }
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        postProcessing.clear(recordingID: entry.recordingID)
    }
}
```

- [ ] **Step 6: Verify the project still builds**

```sh
swift build
```

Expected: clean build. (No new SwiftUI tests — view rendering is QA-verified in Task 16.)

- [ ] **Step 7: Commit**

```sh
git add Sources/HarcUI/
git commit -m "$(cat <<'EOF'
feat(ui): popover post-stop tray binds to RecordingPostProcessingState

Inline 'Identifying speakers…' / '✓ N speakers identified' / '⚠ Retry'
row above the Copy/Open buttons, reading from the env-injected
RecordingPostProcessingState. Copy-for-prompt is disabled during
.identifying; Copy plain text and Open are unaffected. .done auto-
collapses after 1.5 s.

The retry closure is threaded from the call site (AppDelegate, wired
in a follow-up task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: HarcUI — `TranscriptionDetailView` skeleton + retry button

**Files:**
- Modify: `Sources/HarcUI/TranscriptionDetailView.swift`
- Modify: `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift` (env-inject the state)

- [ ] **Step 1: Inject `RecordingPostProcessingState` as `@EnvironmentObject`**

Edit `Sources/HarcUI/TranscriptionDetailView.swift` and add:

```swift
@EnvironmentObject private var postProcessing: RecordingPostProcessingState
```

- [ ] **Step 2: Compute the speaker-editor phase for this recording**

Inside `TranscriptionDetailView`'s body / supporting computed properties, add:

```swift
private enum SpeakerSection {
    case identifying
    case ready                       // editor renders normally
    case empty(retryAvailable: Bool) // recording has no embeddings; user can run "Identify speakers"
    case failed(message: String)
}

private var speakerSection: SpeakerSection {
    if let entry = postProcessing.current, entry.recordingID == recording.id {
        switch entry.phase {
        case .identifying: return .identifying
        case .failed(let msg): return .failed(message: msg)
        case .done, .idle: break
        }
    }
    // No active in-flight job. Decide based on whether the recording has
    // any speaker_embeddings rows. If yes, show the editor; if no, show
    // the "Identify speakers" affordance.
    return hasSpeakerEmbeddings ? .ready : .empty(retryAvailable: true)
}
```

`hasSpeakerEmbeddings` is a state-loaded `Bool` populated on view appear. Add:

```swift
@State private var hasSpeakerEmbeddings: Bool = false

func loadHasEmbeddings() async {
    guard let id = recording.id else { return }
    let count = (try? await store.allSpeakerEmbeddings(
        excludingRecording: nil,
        embedderKind: EmbedderKind.wespeakerV2
    ).filter { $0.recordingID == id }.count) ?? 0
    self.hasSpeakerEmbeddings = count > 0
}
```

(`store` is whatever store accessor the view already uses; match its naming.)

In the `.task { ... }` modifier on the view's root, call `await loadHasEmbeddings()` and re-call when `postProcessing.current` flips to `.done` for this recording.

- [ ] **Step 3: Replace the speaker-editor mount with a phase switch**

Find the existing `SpeakerNameEditor(...)` invocation. Replace with:

```swift
switch speakerSection {
case .identifying:
    HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Identifying speakers…")
            .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)

case .failed(let msg):
    HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text("Couldn't identify speakers")
        Button("Retry") { onIdentifySpeakers() }
            .buttonStyle(.borderless)
    }
    .help(msg)
    .padding(.vertical, 8)

case .empty:
    HStack(spacing: 6) {
        Image(systemName: "person.wave.2").foregroundStyle(.secondary)
        Text("No speaker labels yet")
            .foregroundStyle(.secondary)
        Button("Identify speakers") { onIdentifySpeakers() }
            .buttonStyle(.borderless)
    }
    .padding(.vertical, 8)

case .ready:
    SpeakerNameEditor(
        // … existing args, including suggestionsProvider
    )
}
```

`onIdentifySpeakers` is a closure passed in from the window controller — to be wired in Task 14.

- [ ] **Step 4: Update `TranscriptionDetailView`'s `init` to accept `onIdentifySpeakers: @escaping () -> Void`**

Add the parameter to the init signature and store it as a property. Existing call sites that don't pass it need updating.

- [ ] **Step 5: Update `TranscriptionDetailWindowController` to pass the closure and env-inject the state**

Edit `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`:
- Inject the post-processing state via `@EnvironmentObject` propagation:
  ```swift
  let view = TranscriptionDetailView(
      recording: recording,
      onIdentifySpeakers: { [weak self] in self?.requestIdentifySpeakers() }
  )
  .environmentObject(postProcessingState)
  ```
- The `requestIdentifySpeakers` method calls into AppDelegate's diarize-runner (wired in Task 14). For now, leave it as `// TODO Task 14: trigger diarize` and a `print(...)`.

- [ ] **Step 6: Build to verify it compiles**

```sh
swift build
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

(The Xcode build is needed because `HarcApp` is the Xcode target; SwiftPM alone won't catch app-target breakage.)

Expected: clean build.

- [ ] **Step 7: Commit**

```sh
git add Sources/HarcUI/TranscriptionDetailView.swift HarcApp/WindowControllers/TranscriptionDetailWindowController.swift
git commit -m "$(cat <<'EOF'
feat(ui): TranscriptionDetailView speaker section gates on post-stop state

Renders one of:
- 'Identifying speakers…' skeleton during .identifying
- '⚠ Retry' on .failed
- 'Identify speakers' button when the recording has no embeddings
- SpeakerNameEditor when ready

The 'Identify speakers' / 'Retry' buttons call an onIdentifySpeakers
closure threaded from TranscriptionDetailWindowController; the actual
diarize trigger is wired in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase E — App wiring and HarcVoiceprint cleanup

These tasks land the actual app-level integration: AppDelegate replaces the stub-extractor with the new diarize-call path, the menu-bar status item gains the spinner, and the on-demand "Identify speakers" trigger is wired. Finally, the now-unused stub embedder + extractor + protocol are deleted.

---

### Task 14: HarcApp — replace stub-extractor wiring with diarize-call wiring

**Files:**
- Modify: `HarcApp/AppDelegate.swift`
- Modify: any glue that previously instantiated `StubSpeakerEmbedder` / called `SpeakerExtractor.extract`

- [ ] **Step 1: Locate the existing stub-embedder wiring**

```sh
grep -n "StubSpeakerEmbedder\|SpeakerExtractor" HarcApp/AppDelegate.swift
```

You'll find an instantiation of `StubSpeakerEmbedder()` and a detached `Task` that invokes `SpeakerExtractor.extract` after the recording stops. The `SpeakerReIDService` is also instantiated near here.

- [ ] **Step 2: Add a `RecordingPostProcessingState` instance and inject it**

In `AppDelegate.swift`'s property block:

```swift
private let postProcessingState = RecordingPostProcessingState()
```

When constructing the popover view tree (and the detail-window view trees), add `.environmentObject(postProcessingState)` to the env chain.

- [ ] **Step 3: Replace the stub-extractor task with a diarize-driven path**

The relevant lifecycle is: recording stops → `ChunkedTranscriber.finalize` is called → returns a `ChunkedTranscriberFinalize`. AppDelegate's existing handler likely already awaits the final transcript and then writes the recording row + extracted embeddings.

Replace it. The new shape:

```swift
// On stopRecording:
postProcessingState.begin(recordingID: pendingRecordingID)   // see note below

let final = try await chunkedTranscriber.finalize(
    startedAt: recordingStartedAt,
    endedAt: Date()
)

// Write the recording row through the existing RecordingIngestor path.
let recording = try await ingestor.ingest(
    transcript: final.transcript,
    /* ... */
)

// Persist embeddings — translate from HarcCore.SpeakerEmbeddingRow (wire
// type) to HarcStore.RecordingStore.SpeakerEmbeddingRow (DB row type).
if !final.speakerEmbeddings.isEmpty {
    let dbRows: [RecordingStore.SpeakerEmbeddingRow] = final.speakerEmbeddings.map {
        RecordingStore.SpeakerEmbeddingRow(
            recordingID: recording.id!,
            speakerIndex: $0.speakerIndex,
            embedding: EmbeddingBlob.encode($0.vector),
            segmentCount: $0.segmentCount,
            totalMs: $0.totalMs,
            embedderKind: EmbedderKind.wespeakerV2
        )
    }
    try await store.upsertSpeakerEmbeddings(
        recordingID: recording.id!,
        rows: dbRows
    )
    postProcessingState.succeed(
        recordingID: recording.id!,
        speakerCount: final.speakerEmbeddings.count
    )
} else if let err = final.diarizationError {
    postProcessingState.fail(
        recordingID: recording.id!,
        message: err
    )
} else {
    // Diarize returned zero speakers — collapse the row immediately.
    postProcessingState.succeed(recordingID: recording.id!, speakerCount: 0)
}
```

**Note on `pendingRecordingID`:** the recording row's ID isn't known until *after* `ingestor.ingest` returns. So `begin()` needs to fire on a "best-known" ID. Two options:

(a) Eagerly create the recording row on stop (before `finalize`) so we have its ID before `begin()`. Simpler to reason about; matches how the existing AppDelegate writes things — check if it already does this.

(b) Defer `begin()` until immediately after `ingestor.ingest`. The status indicator shows up a beat later — fine for the 3–10 s post-stop window.

Pick whichever matches the existing AppDelegate's current ordering. Document the choice in a comment.

- [ ] **Step 4: Construct and inject the `ChunkedTranscriber` with a diarizer**

The transcriber's init now takes a `diarizer: any DiarizingClient`. Pass the same `HarcSTTClient` instance (it conforms to both `TranscribingClient` and `DiarizingClient`):

```swift
let chunkedTranscriber = ChunkedTranscriber(
    client: sttClient,
    diarizer: sttClient,
    vadEnabled: prefs.vadEnabled,
    chunkDurationSeconds: prefs.chunkDurationSeconds,
    pollIntervalSeconds: 2.0,
    vocabulary: vocabulary
)
```

- [ ] **Step 5: Wire the "Identify speakers" / "Retry" trigger**

Add a method on AppDelegate (or a small coordinator class) that takes a recording ID, runs `client.diarize(audioPath:)` against the recording's WAV path, writes embeddings, and updates `postProcessingState`:

```swift
func runIdentifySpeakers(recordingID: Int64) {
    Task { @MainActor in
        guard let recording = try? await store.fetch(id: recordingID) else {
            postProcessingState.fail(recordingID: recordingID, message: "Recording not found")
            return
        }
        postProcessingState.begin(recordingID: recordingID)
        do {
            let result = try await sttClient.diarize(audioPath: recording.wavPath)
            let dbRows: [RecordingStore.SpeakerEmbeddingRow] = result.speakers.map {
                RecordingStore.SpeakerEmbeddingRow(
                    recordingID: recordingID,
                    speakerIndex: $0.speakerIndex,
                    embedding: EmbeddingBlob.encode($0.vector),
                    segmentCount: $0.segmentCount,
                    totalMs: $0.totalMs,
                    embedderKind: EmbedderKind.wespeakerV2
                )
            }
            try await store.upsertSpeakerEmbeddings(recordingID: recordingID, rows: dbRows)
            postProcessingState.succeed(recordingID: recordingID, speakerCount: result.speakers.count)
        } catch {
            postProcessingState.fail(recordingID: recordingID, message: error.localizedDescription)
        }
    }
}
```

Pass this method (or a closure that calls it) into:
- `TranscriptionDetailWindowController` (so the "Identify speakers" / "Retry" buttons in the detail view fire it).
- Wherever the popover's "Retry" button lives (so the popover row's retry fires it).

- [ ] **Step 6: Add the menu-bar status-item indicator binding**

Find where the status item's `image` is set. Add a `Combine.sink` (or `withObservationTracking` if SwiftUI patterns are used) that observes `postProcessingState.$current` and updates the image:

```swift
postProcessingState.$current
    .receive(on: DispatchQueue.main)
    .sink { [weak self] entry in
        guard let self else { return }
        switch entry?.phase {
        case .identifying:
            self.statusItem?.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Identifying speakers…")
            self.statusItem?.button?.toolTip = "Identifying speakers…"
        case .failed:
            self.statusItem?.button?.image = self.idleStatusItemImage()
            self.statusItem?.button?.toolTip = "Couldn't identify speakers — open recording to retry"
        case .done, .idle, nil:
            self.statusItem?.button?.image = self.idleStatusItemImage()
            self.statusItem?.button?.toolTip = nil
        }
    }
    .store(in: &cancellables)
```

(Adjust to match the AppDelegate's existing Combine setup. If there is no `cancellables` set, add one.)

- [ ] **Step 7: Remove the old `StubSpeakerEmbedder()` instantiation and the `SpeakerExtractor.extract` task**

Delete those lines. The `SpeakerReIDService` instantiation stays, but its constructor no longer needs an embedder argument (review the existing init — it likely takes `(store, resolver)` only and does not require an embedder).

- [ ] **Step 8: Build and run**

```sh
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Expected: clean build. Then run the app from Xcode and do a quick smoke: start a recording, stop it, watch the popover for the "Identifying speakers…" → "✓" sequence.

- [ ] **Step 9: Commit**

```sh
git add HarcApp/
git commit -m "$(cat <<'EOF'
feat(app): wire RecordingPostProcessingState + diarize-driven identity

Stop-of-recording flow:
1. ChunkedTranscriber.finalize returns transcript + speaker embeddings.
2. RecordingIngestor writes the recording row.
3. Embeddings are translated to RecordingStore row format and persisted
   with embedderKind = wespeaker_v2.
4. postProcessingState.succeed/fail drives the popover + menu-bar status
   indicator + detail-view skeleton.

Adds runIdentifySpeakers(recordingID:) for the on-demand
'Identify speakers' / 'Retry' buttons (popover and detail view).

Removes StubSpeakerEmbedder and the SpeakerExtractor.extract task —
embedder lives in FluidAudio now, called from the daemon's diarize verb.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: HarcVoiceprint cleanup — delete `StubSpeakerEmbedder`, protocol, `SpeakerExtractor`, error type

**Files:**
- Delete: `Sources/HarcVoiceprint/StubSpeakerEmbedder.swift`
- Delete: `Sources/HarcVoiceprint/SpeakerExtractor.swift`
- Delete: `Tests/HarcVoiceprintTests/StubSpeakerEmbedderTests.swift` (and any `SpeakerExtractor` tests if they exist)
- Modify: `Sources/HarcVoiceprint/SpeakerEmbedder.swift` — keep helpers, drop protocol + error

- [ ] **Step 1: Verify nothing else references the to-be-deleted symbols**

```sh
grep -rn "StubSpeakerEmbedder\|SpeakerExtractor\|SpeakerEmbedder protocol\|SpeakerEmbedderError" Sources/ Tests/ HarcApp/ 2>/dev/null
```

Expected: only matches inside the files about to be deleted (and possibly within `SpeakerEmbedder.swift` itself). If any other file still imports/uses them, return to Task 14 — that file has work that wasn't completed.

- [ ] **Step 2: Delete the stub and extractor files**

```sh
git rm Sources/HarcVoiceprint/StubSpeakerEmbedder.swift
git rm Sources/HarcVoiceprint/SpeakerExtractor.swift
git rm Tests/HarcVoiceprintTests/StubSpeakerEmbedderTests.swift
# If a SpeakerExtractor test file exists, rm it too:
ls Tests/HarcVoiceprintTests/SpeakerExtractor*Tests.swift 2>/dev/null && git rm Tests/HarcVoiceprintTests/SpeakerExtractor*Tests.swift
```

- [ ] **Step 3: Strip the protocol and error type from `SpeakerEmbedder.swift`**

Edit `Sources/HarcVoiceprint/SpeakerEmbedder.swift`. Replace its entire content with:

```swift
import Foundation

/// One extracted embedding + the metadata needed to decide whether it's
/// worth keeping. Independent of the producer — both daemon-side
/// computation and store-side decoding can build / consume this.
public struct SpeakerEmbedding: Sendable, Equatable {
    public let speakerIndex: Int
    public let vector: [Float]
    public let segmentCount: Int
    public let totalMs: Int

    public init(speakerIndex: Int, vector: [Float], segmentCount: Int, totalMs: Int) {
        self.speakerIndex = speakerIndex
        self.vector = vector
        self.segmentCount = segmentCount
        self.totalMs = totalMs
    }
}

// MARK: - Cosine similarity

public enum CosineSimilarity {
    /// Cosine similarity between two equal-length Float vectors. Returns 0
    /// when either vector is empty or lengths differ; L2-norm zero is
    /// treated as 0 similarity.
    public static func of(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        return denom > 0 ? dot / denom : 0
    }

    /// Cosine similarity assuming both inputs are already L2-normalized. A
    /// single dot product — cheaper than the general `of(...)` when a
    /// batch of candidates is normalized ahead of time.
    public static func dotNormalized(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }
}

/// L2-normalize a vector in place. No-op if the norm is zero.
public func l2Normalize(_ v: inout [Float]) {
    var sumSq: Float = 0
    for x in v { sumSq += x * x }
    let norm = sqrtf(sumSq)
    guard norm > 0 else { return }
    for i in 0..<v.count { v[i] /= norm }
}
```

(`SpeakerEmbedder` protocol and `SpeakerEmbedderError` are removed. The remaining types — `SpeakerEmbedding`, `CosineSimilarity`, `l2Normalize` — keep their public API.)

- [ ] **Step 4: Run the full test suite**

```sh
swift test
```

Expected: every test target passes. If something fails, it's a missed call site from Task 14 — fix in place, then continue.

- [ ] **Step 5: Build the Xcode app target**

```sh
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```sh
git add Sources/HarcVoiceprint/SpeakerEmbedder.swift Tests/HarcVoiceprintTests/
git commit -m "$(cat <<'EOF'
chore(voiceprint): remove StubSpeakerEmbedder, SpeakerExtractor, protocol

The embedder now lives inside FluidAudio (WeSpeaker v2), called from
the daemon's diarize verb. The placeholder stub, the SpeakerEmbedder
protocol (one-implementation, no remaining call sites), and the
SpeakerExtractor (load-WAV-and-slice-segments pipeline, replaced by
inline FluidAudio embedding) are deleted.

Module shrinks to EmbeddingBlob, CosineSimilarity, l2Normalize,
SpeakerEmbedding domain type, and EmbedderKind constants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase F — End-to-end verification

### Task 16: Manual QA

Run through the manual scenarios from spec §9.3 on a real install. Each scenario builds confidence the design holds together.

- [ ] **Scenario 1: Within-recording fix.**
  - Record a 5-minute conversation with two speakers (you + one other person, or two TTS voices played out loud).
  - Stop. Watch popover for "⟳ Identifying speakers…" indicator (≤ 15 s).
  - Open the recording in detail view.
  - **Pass criteria:** Speaker 1 is consistently the same person throughout; Speaker 2 is consistently the other. No mid-conversation flips.

- [ ] **Scenario 2: Force-quit recovery.**
  - Start a recording, stop it, immediately force-quit the app during the post-processing window.
  - Relaunch the app.
  - Open the recording in the library.
  - **Pass criteria:** Transcript text is intact. The detail view shows an "Identify speakers" button instead of the editor. Clicking it triggers diarize; speaker rows populate within ~10 s.

- [ ] **Scenario 3: Cross-recording suggestion.**
  - Record three short meetings (≥ 30 s each) that include a second voice.
  - In the first recording's detail view, name "Speaker 1" as e.g. "Maria".
  - Open the second recording's detail view.
  - **Pass criteria:** A suggestion chip appears below Speaker 1 saying "Sounds like Maria · 1 prior recording · NN%". Clicking it fills the field with "Maria" and offers to propagate to the third recording.

- [ ] **Scenario 4: Failure path.**
  - With the app running, kill the daemon process: `kill $(pgrep -f harc-stt)`.
  - Stop a recording in progress (or press the popover's retry on a previously-failed one).
  - **Pass criteria:** Popover shows "⚠ Couldn't identify speakers — Retry". Clicking Retry re-runs the daemon (DaemonLauncher reconnects) and succeeds on second attempt.

- [ ] **Scenario 5: Long meeting.**
  - Record a 30+ minute meeting with two voices (use a YouTube interview / podcast played out loud if needed).
  - Stop.
  - **Pass criteria:** Diarization completes in ≤ 30 s. Transcript text was complete the whole time. Speaker labels are correct end-to-end.

- [ ] **Scenario 6: Settings flip respected.**
  - Toggle off `speakerReIDEnabled` in Settings.
  - Open a recording's detail view.
  - **Pass criteria:** Suggestion chips do not appear (existing behavior). Speaker editor still renders correctly.

If all six scenarios pass, the implementation is complete.

---

## Spec self-review checklist

Before declaring the plan done, the spec at [docs/superpowers/specs/2026-04-26-speaker-identity-design.md](../specs/2026-04-26-speaker-identity-design.md) covers:

- [x] §1 Problem statement — covered by tasks 5, 6, 8 (within-recording fix) + 9 (cross-recording).
- [x] §2 In-scope items: new `diarize` IPC verb (task 1, 6, 7); `ChunkedTranscriber` change (task 8); migration v9 (task 3); `embedder_kind` (tasks 3, 4); deletion of stub/protocol/extractor (task 15); `RecordingPostProcessingState` (task 11); `speakerReIDEnabled` flip (task 10); threshold 0.65 (task 9).
- [x] §3 Shipped-vs-changed inventory — all "deleted" items struck through in tasks 14, 15.
- [x] §4 Data flow diagram — implemented across tasks 5, 6, 7, 8, 14.
- [x] §5 IPC types — task 1.
- [x] §6 Schema migration v9 + EmbedderKind constant — tasks 2, 3.
- [x] §7 Post-stop UX with menu-bar / popover / detail-view + failure semantics — tasks 11, 12, 13, 14.
- [x] §8 Module-by-module change summary — task allocation matches.
- [x] §9 Tests (unit + integration + manual QA) — covered by tests in tasks 1–11 and manual scenarios in task 16.
- [x] §10 Rollout: single migration, no backfill, no feature flag — implicit in the task ordering.
- [x] §11 Risks — addressed by failure-handling in tasks 6, 8, 14.
- [x] §12 Open questions — threshold tuning (similarity log) intentionally not implemented in v1; flagged for a follow-up task post-launch.

No gaps. No placeholders. Type/method names consistent across tasks.
