# Harc Library, Search & Auto-Paste Implementation Plan (Plan 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plan 5's filesystem-scanning `RecordingsIndex` with a GRDB/SQLite-backed store (`RecordingStore`) that enables full-text search, renaming, pinning, and soft-delete. Add a dedicated Library window with a search field and virtualized list for browsing hundreds of recordings. Add "Copy to clipboard" + "Paste into frontmost app" actions (the latter via CGEvent keyboard injection, requiring Accessibility permission).

**Architecture:** New library target `HarcStore` owns the GRDB database setup, migrations, and data access. On app launch, a filesystem ingestor finds any WAV files not yet in the database and inserts rows (keyed by `wav_path`). An FTS5 virtual table indexes the transcript text for fast full-text search. The popover's Recent list and the new Library window both read from `RecordingStore` via an `@Observable` query model. `TranscriptionDetailView` gains a "Paste into frontmost" button powered by a small `FrontmostAppPaster` helper.

**Tech Stack:** Swift 6.0, SwiftPM, Swift Testing, [GRDB.swift](https://github.com/groue/GRDB.swift) 6.29+, SQLite FTS5 (bundled with GRDB), `NSPasteboard`, `CGEvent` + `NSWorkspace.shared.runningApplications` for frontmost-app paste, Accessibility TCC permission.

---

## Prerequisites

- Plans 1–5 complete on `main`. Latest commit `cf40081 feat: eager daemon launch + live transcript preview in popover`. `swift test` passes 54 tests in 23 suites.
- At least one recording exists at `~/Documents/Harc/YYYY/YYYY-MM-DD/HH-mm-ss.{wav,txt,json}` from prior smoke testing.
- Menu bar app launches, popover shows Recent list, hotkey works.

## Scope Boundary

**In:**
- GRDB + SQLite-backed `RecordingStore` replacing `RecordingsIndex`
- FTS5 full-text search
- Library window (full NSWindow, not popover) with search bar + list
- Rename (user-editable title), pin (sorts pinned first), soft-delete (`deleted_at` IS NULL filter on normal views)
- Copy transcript to clipboard + Paste into frontmost app (CGEvent injection, Accessibility-gated)
- Ingestion of existing filesystem recordings on first launch after upgrade
- Deferred polish items from Plan 5: window-close callbacks, subscription Task cancellation, reactive destination path, gitignore `HarcApp/Info.plist`

**Out (later plans):**
- Trash UI for restoring soft-deleted items
- Export to PDF / Markdown / plain text batch
- Search filters (by date range, speaker count, pinned only)
- Sync across devices (iCloud, Dropbox)
- Onboarding wizard for TCC permissions

## File Structure

After Plan 6:

```
Harc/
├── Package.swift                                        (modified — +HarcStore, +GRDB dep)
├── project.yml                                          (modified — +HarcStore dep on Harc target)
├── .gitignore                                           (modified — +HarcApp/Info.plist)
├── Sources/
│   ├── HarcStore/                                       (new library target)
│   │   ├── Recording.swift                              T1 — model struct
│   │   ├── RecordingStore.swift                         T2 — GRDB-backed CRUD + search
│   │   ├── StoreError.swift                             T1
│   │   ├── DatabaseMigrator+Harc.swift                  T1 — schema migration
│   │   └── RecordingIngestor.swift                      T3 — fs → DB
│   ├── HarcUI/
│   │   ├── RecordingsIndex.swift                        (deleted)  T4
│   │   ├── RecentRecordingsView.swift                   (modified — consumes RecordingStore)  T4
│   │   ├── LibraryWindowRootView.swift                  T5
│   │   ├── LibraryViewModel.swift                       T5
│   │   ├── LibrarySearchField.swift                     T5
│   │   ├── LibraryRowActions.swift                      T6 — rename/pin/delete menu
│   │   └── FrontmostAppPaster.swift                     T7
│   ├── (HarcCore, HarcAudio, HarcClient unchanged)
│   └── HarcSTT (unchanged)
├── HarcApp/
│   ├── AppDelegate.swift                                (modified — wire RecordingStore + library window)  T3-T8
│   └── WindowControllers/
│       └── LibraryWindowController.swift                T5
└── Tests/
    └── HarcStoreTests/                                  (new test target)
        ├── RecordingStoreTests.swift                    T2
        ├── RecordingIngestorTests.swift                 T3
        └── MigrationTests.swift                         T1
```

### Responsibilities

- **`Recording`** — plain value type representing a row. `id: Int64`, `wavPath: String`, `txtPath: String?`, `jsonPath: String?`, `startedAt: Date`, `endedAt: Date?`, `title: String?` (user-editable, nullable — falls back to timestamp), `transcriptText: String?` (cached for FTS), `pinned: Bool`, `deletedAt: Date?`, `createdAt: Date`, `updatedAt: Date`. Conforms to `Codable`, `FetchableRecord`, `PersistableRecord`, `Hashable`, `Sendable`.
- **`RecordingStore`** — actor owning the `DatabaseQueue`. CRUD: `upsert(_:)`, `fetchAll(includeDeleted:pinnedFirst:)`, `fetchByWavPath(_:)`, `search(query:includeDeleted:)`, `rename(id:title:)`, `setPinned(id:pinned:)`, `softDelete(id:)`, `restore(id:)`, `observeAll()` (AsyncStream of `[Recording]` that re-emits on any mutation).
- **`StoreError`** — typed errors: `.databaseOpenFailed(String)`, `.migrationFailed(String)`, `.notFound`, `.writeFailed(String)`.
- **`DatabaseMigrator+Harc`** — Single GRDB migration that creates `recordings` table + `recordings_fts` virtual table + insert/delete/update triggers that keep FTS in sync.
- **`RecordingIngestor`** — on app launch, scan the destination folder for WAVs, upsert any rows not already in the DB. Reuses Plan 5's `RecordingsIndex` scan logic for the filesystem traversal, just writes to `RecordingStore` instead of a `@Published` array.
- **`LibraryViewModel`** — `@MainActor ObservableObject`. Observes `RecordingStore.observeAll()`. `@Published var recordings: [Recording]`, `@Published var searchText: String` (debounced to 200ms, triggers `store.search(...)` when non-empty). Exposes actions (`rename(_:)`, `togglePin(_:)`, `delete(_:)`) that call the store.
- **`LibraryWindowRootView`** — full-window SwiftUI. Top bar with `LibrarySearchField`, virtualized list (`List` with `@ForEach(recordings)` — SwiftUI virtualizes `List` on macOS 14+). Row shows date + title + preview. Context menu per row: Open, Copy, Reveal, Rename, Pin/Unpin, Delete.
- **`LibraryRowActions`** — shared view (used by Library window + TranscriptionDetailView) that renders the action buttons/menu.
- **`FrontmostAppPaster`** — helper. Given a string, writes to `NSPasteboard.general`, then uses `CGEvent` to synthesize ⌘V into the frontmost application (via `NSWorkspace.shared.frontmostApplication`). Returns `Bool` for success or throws on permission denial.
- **`LibraryWindowController`** — `@MainActor NSWindowController` wrapping `LibraryWindowRootView` in an NSWindow. 960×640 default. Caches per AppDelegate.

## Migration + Ingestion Strategy

On first launch after upgrade:
1. `RecordingStore.init()` opens (or creates) `~/Library/Application Support/Harc/Harc.db`.
2. `DatabaseMigrator` runs any pending migrations — creates tables + FTS.
3. `RecordingIngestor.ingestAll()` scans `~/Documents/Harc/`, finds WAVs not yet in the DB (by `wav_path`), reads their `.txt` siblings for transcript text, inserts rows.
4. Popover's Recent list + Library window query the DB.

Subsequent launches: same migration runs (no-op if already applied), ingestor only picks up new files (e.g., if user restored from Time Machine).

## Testing Notes

- `RecordingStoreTests` uses in-memory GRDB (`DatabaseQueue()` with no path) — fast, isolated per test.
- `RecordingIngestorTests` creates temp dirs with fake `.wav`/`.txt` trios, runs ingestor against an in-memory DB.
- `MigrationTests` verifies the FTS table + triggers fire correctly on insert/update/delete.
- Library view rendering is not unit-tested (manual smoke).
- `FrontmostAppPaster` has one logic test (clipboard write) + manual smoke for the CGEvent injection.

---

### Task 1: `HarcStore` target + `Recording` model + migrations

Adds the GRDB dependency, new library target, Recording model, and the schema migration.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Modify: `/Users/jlane/GitHub/Harc/project.yml`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/Recording.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/StoreError.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/DatabaseMigrator+Harc.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/MigrationTests.swift`

- [ ] **Step 1: Update `Package.swift`** — add HarcStore target + test target, add GRDB dep

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcAudio", targets: ["HarcAudio"]),
        .library(name: "HarcClient", targets: ["HarcClient"]),
        .library(name: "HarcStore", targets: ["HarcStore"]),
        .library(name: "HarcUI", targets: ["HarcUI"]),
        .executable(name: "harc-stt", targets: ["HarcSTT"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.13.5")
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            from: "2.3.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "6.29.0"
        ),
    ],
    targets: [
        .target(name: "HarcCore"),
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore", "HarcClient"]
        ),
        .target(
            name: "HarcClient",
            dependencies: ["HarcCore"]
        ),
        .target(
            name: "HarcStore",
            dependencies: [
                "HarcCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "HarcUI",
            dependencies: [
                "HarcCore",
                "HarcAudio",
                "HarcClient",
                "HarcStore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .executableTarget(
            name: "HarcSTT",
            dependencies: [
                "HarcCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "HarcCoreTests", dependencies: ["HarcCore"]),
        .testTarget(
            name: "HarcSTTTests",
            dependencies: ["HarcSTT", "HarcCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HarcAudioTests",
            dependencies: ["HarcAudio", "HarcCore", "HarcClient"]
        ),
        .testTarget(
            name: "HarcClientTests",
            dependencies: ["HarcClient", "HarcCore"]
        ),
        .testTarget(
            name: "HarcUITests",
            dependencies: ["HarcUI", "HarcCore"]
        ),
        .testTarget(
            name: "HarcStoreTests",
            dependencies: ["HarcStore", "HarcCore"]
        ),
    ]
)
```

- [ ] **Step 2: Update `project.yml`** — add HarcStore as fifth product dep on Harc target

Under `targets.Harc.dependencies:`, ADD a fifth entry so the block reads:

```yaml
    dependencies:
      - package: HarcCore
        product: HarcCore
      - package: HarcCore
        product: HarcAudio
      - package: HarcCore
        product: HarcClient
      - package: HarcCore
        product: HarcStore
      - package: HarcCore
        product: HarcUI
```

- [ ] **Step 3: Write `Sources/HarcStore/StoreError.swift`**

```swift
import Foundation

public enum StoreError: Error, LocalizedError, Equatable {
    case databaseOpenFailed(String)
    case migrationFailed(String)
    case notFound
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let reason):
            return "Failed to open database: \(reason)"
        case .migrationFailed(let reason):
            return "Database migration failed: \(reason)"
        case .notFound:
            return "Recording not found"
        case .writeFailed(let reason):
            return "Database write failed: \(reason)"
        }
    }
}
```

- [ ] **Step 4: Write `Sources/HarcStore/Recording.swift`**

```swift
import Foundation
import GRDB

/// A single recording row. Mirrors the `recordings` table.
public struct Recording: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: Int64?
    public var wavPath: String
    public var txtPath: String?
    public var jsonPath: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var title: String?
    public var transcriptText: String?
    public var pinned: Bool
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        wavPath: String,
        txtPath: String? = nil,
        jsonPath: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        transcriptText: String? = nil,
        pinned: Bool = false,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.wavPath = wavPath
        self.txtPath = txtPath
        self.jsonPath = jsonPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.transcriptText = transcriptText
        self.pinned = pinned
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Display title: user's custom title if set, else derived from startedAt.
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: startedAt)
    }

    /// First ~120 chars of transcript, trimmed. Empty string if no transcript.
    public var preview: String {
        guard let text = transcriptText else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }
}

extension Recording: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "recordings"

    // Map Swift camelCase property names to snake_case column names.
    // GRDB's PersistableRecord + Codable uses CodingKeys to derive column names
    // for insert/update SQL. Without this the generated SQL says "wavPath" etc.
    // which doesn't match the schema's "wav_path" columns.
    private enum CodingKeys: String, CodingKey {
        case id
        case wavPath = "wav_path"
        case txtPath = "txt_path"
        case jsonPath = "json_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case transcriptText = "transcript_text"
        case pinned
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public enum Columns {
        static let id = Column("id")
        static let wavPath = Column("wav_path")
        static let txtPath = Column("txt_path")
        static let jsonPath = Column("json_path")
        static let startedAt = Column("started_at")
        static let endedAt = Column("ended_at")
        static let title = Column("title")
        static let transcriptText = Column("transcript_text")
        static let pinned = Column("pinned")
        static let deletedAt = Column("deleted_at")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }
}
```

- [ ] **Step 5: Write `Sources/HarcStore/DatabaseMigrator+Harc.swift`**

```swift
import Foundation
import GRDB

extension DatabaseMigrator {
    /// Harc's schema migrations. Call `try harcMigrator().migrate(dbQueue)` on
    /// store init.
    public static func harcMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_recordings_and_fts") { db in
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

            try db.create(
                virtualTable: "recordings_fts",
                using: FTS5()
            ) { t in
                t.synchronize(withTable: "recordings")
                t.column("title")
                t.column("transcript_text")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        return migrator
    }
}
```

- [ ] **Step 6: Write the migration test `Tests/HarcStoreTests/MigrationTests.swift`**

```swift
import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("DatabaseMigrator")
struct MigrationTests {
    @Test("harcMigrator creates recordings table + FTS virtual table")
    func migrationCreatesTables() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            #expect(tables.contains("recordings"))
            #expect(tables.contains("recordings_fts"))
        }
    }

    @Test("migration is idempotent — second run is a no-op")
    func migrationIdempotent() throws {
        let dbq = try DatabaseQueue()
        let migrator = DatabaseMigrator.harcMigrator()
        try migrator.migrate(dbq)
        // Second run should not throw.
        try migrator.migrate(dbq)

        try dbq.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' AND name='recordings'"
            )
            #expect(tables.count == 1)
        }
    }

    @Test("FTS sync reflects inserts into recordings")
    func ftsSyncOnInsert() throws {
        let dbq = try DatabaseQueue()
        try DatabaseMigrator.harcMigrator().migrate(dbq)

        try dbq.write { db in
            let now = Date()
            var rec = Recording(
                wavPath: "/tmp/fake.wav",
                startedAt: now,
                title: "Meeting with Alice",
                transcriptText: "discussing quarterly earnings"
            )
            try rec.insert(db)

            let matches = try Row.fetchAll(db, sql:
                "SELECT rowid, title FROM recordings_fts WHERE recordings_fts MATCH 'quarterly'"
            )
            #expect(matches.count == 1)
        }
    }
}
```

- [ ] **Step 7: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter MigrationTests 2>&1 | tail -15
```

Expected: compile errors — GRDB not resolved, types missing.

- [ ] **Step 8: Build to pull GRDB**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
```

Expected: GRDB fetches + compiles (~30-60s first time), `Build complete!`.

- [ ] **Step 9: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter MigrationTests 2>&1 | tail -15
```

Expected: 3 MigrationTests pass.

- [ ] **Step 10: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 57 tests in 24 suites (54 prior + 3 new).

- [ ] **Step 11: Rebuild Xcode + verify app builds**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj
xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 12: Commit**

```bash
git add Package.swift Package.resolved project.yml Sources/HarcStore Tests/HarcStoreTests
git commit -m "feat: HarcStore with GRDB + Recording model + FTS5 schema migration"
```

---

### Task 2: `RecordingStore` — GRDB-backed CRUD + search

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/RecordingStore.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/RecordingStoreTests.swift`

- [ ] **Step 1: Write the failing tests `Tests/HarcStoreTests/RecordingStoreTests.swift`**

```swift
import Testing
import Foundation
import GRDB
@testable import HarcStore

@Suite("RecordingStore")
struct RecordingStoreTests {
    private func makeInMemoryStore() async throws -> RecordingStore {
        try await RecordingStore.inMemory()
    }

    private func sampleRecording(wavPath: String = "/tmp/a.wav", title: String? = nil) -> Recording {
        Recording(
            wavPath: wavPath,
            txtPath: wavPath.replacingOccurrences(of: ".wav", with: ".txt"),
            jsonPath: wavPath.replacingOccurrences(of: ".wav", with: ".json"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            title: title,
            transcriptText: "hello world"
        )
    }

    @Test("upsert inserts a new recording and returns it with id")
    func upsertInsert() async throws {
        let store = try await makeInMemoryStore()
        let inserted = try await store.upsert(sampleRecording())
        #expect(inserted.id != nil)
        #expect(inserted.wavPath == "/tmp/a.wav")
    }

    @Test("upsert of the same wavPath updates the existing row")
    func upsertUpdate() async throws {
        let store = try await makeInMemoryStore()
        var rec = sampleRecording()
        rec = try await store.upsert(rec)
        let originalId = rec.id
        rec.title = "Renamed"
        rec = try await store.upsert(rec)
        #expect(rec.id == originalId)
        #expect(rec.title == "Renamed")
        let all = try await store.fetchAll()
        #expect(all.count == 1)
    }

    @Test("fetchAll excludes soft-deleted by default, includes them on request")
    func fetchAllFiltering() async throws {
        let store = try await makeInMemoryStore()
        let a = try await store.upsert(sampleRecording(wavPath: "/tmp/a.wav"))
        _ = try await store.upsert(sampleRecording(wavPath: "/tmp/b.wav"))
        try await store.softDelete(id: a.id!)

        let visible = try await store.fetchAll()
        #expect(visible.count == 1)
        #expect(visible[0].wavPath == "/tmp/b.wav")

        let withDeleted = try await store.fetchAll(includeDeleted: true)
        #expect(withDeleted.count == 2)
    }

    @Test("fetchAll with pinnedFirst puts pinned above unpinned, ordered by startedAt desc within groups")
    func pinnedFirstOrdering() async throws {
        let store = try await makeInMemoryStore()
        var older = sampleRecording(wavPath: "/tmp/old.wav")
        older.startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = sampleRecording(wavPath: "/tmp/new.wav")
        _ = try await store.upsert(older)
        let n = try await store.upsert(newer)

        try await store.setPinned(id: n.id!, pinned: false)
        try await store.setPinned(id: (try await store.fetchByWavPath("/tmp/old.wav"))!.id!, pinned: true)

        let ordered = try await store.fetchAll(pinnedFirst: true)
        #expect(ordered[0].wavPath == "/tmp/old.wav", "pinned should come first")
        #expect(ordered[1].wavPath == "/tmp/new.wav")
    }

    @Test("rename updates title and leaves other fields alone")
    func rename() async throws {
        let store = try await makeInMemoryStore()
        let r = try await store.upsert(sampleRecording())
        try await store.rename(id: r.id!, title: "My rename")
        let fetched = try await store.fetchByWavPath(r.wavPath)
        #expect(fetched?.title == "My rename")
    }

    @Test("search finds recordings by transcript text via FTS")
    func searchFTS() async throws {
        let store = try await makeInMemoryStore()
        _ = try await store.upsert(sampleRecording(wavPath: "/tmp/a.wav"))  // "hello world"
        var other = sampleRecording(wavPath: "/tmp/b.wav")
        other.transcriptText = "completely different content"
        _ = try await store.upsert(other)

        let results = try await store.search(query: "hello")
        #expect(results.count == 1)
        #expect(results[0].wavPath == "/tmp/a.wav")
    }

    @Test("search matches against the title field too")
    func searchByTitle() async throws {
        let store = try await makeInMemoryStore()
        var rec = sampleRecording()
        rec.title = "Standup meeting"
        _ = try await store.upsert(rec)

        let results = try await store.search(query: "standup")
        #expect(results.count == 1)
    }

    @Test("softDelete sets deletedAt; restore clears it")
    func softDeleteAndRestore() async throws {
        let store = try await makeInMemoryStore()
        let r = try await store.upsert(sampleRecording())
        try await store.softDelete(id: r.id!)
        let deleted = try await store.fetchByWavPath(r.wavPath)
        #expect(deleted?.deletedAt != nil)

        try await store.restore(id: r.id!)
        let restored = try await store.fetchByWavPath(r.wavPath)
        #expect(restored?.deletedAt == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingStoreTests 2>&1 | tail -15
```

Expected: `RecordingStore` not found.

- [ ] **Step 3: Write `Sources/HarcStore/RecordingStore.swift`**

```swift
import Foundation
import GRDB

/// GRDB-backed store for `Recording` rows. Actor-isolated; all DB access
/// serializes through `dbQueue` (GRDB's `DatabaseQueue` is itself thread-safe
/// but we funnel through the actor for cleaner Swift-6 concurrency semantics).
public actor RecordingStore {
    private let dbQueue: DatabaseQueue

    /// Default database location: `~/Library/Application Support/Harc/Harc.db`.
    public static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Harc/Harc.db")
    }

    /// Factory — opens (or creates) a file-backed DB, runs migrations.
    public static func onDisk(url: URL = defaultURL()) async throws -> RecordingStore {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dbq: DatabaseQueue
        do {
            dbq = try DatabaseQueue(path: url.path)
        } catch {
            throw StoreError.databaseOpenFailed(error.localizedDescription)
        }
        do {
            try DatabaseMigrator.harcMigrator().migrate(dbq)
        } catch {
            throw StoreError.migrationFailed(error.localizedDescription)
        }
        return RecordingStore(dbQueue: dbq)
    }

    /// Factory — in-memory DB for tests.
    public static func inMemory() async throws -> RecordingStore {
        let dbq: DatabaseQueue
        do {
            dbq = try DatabaseQueue()
        } catch {
            throw StoreError.databaseOpenFailed(error.localizedDescription)
        }
        do {
            try DatabaseMigrator.harcMigrator().migrate(dbq)
        } catch {
            throw StoreError.migrationFailed(error.localizedDescription)
        }
        return RecordingStore(dbQueue: dbq)
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - CRUD

    /// Insert or update a recording by `wavPath`. Returns the saved row (with id set).
    @discardableResult
    public func upsert(_ recording: Recording) async throws -> Recording {
        do {
            return try await dbQueue.write { db in
                var rec = recording
                rec.updatedAt = Date()
                if let existing = try Recording
                    .filter(Recording.Columns.wavPath == rec.wavPath)
                    .fetchOne(db)
                {
                    rec.id = existing.id
                    rec.createdAt = existing.createdAt
                    try rec.update(db)
                } else {
                    rec.createdAt = Date()
                    try rec.insert(db)
                    // PersistableRecord's didInsert is non-mutating on structs;
                    // fetch the auto-incremented id from the DB and stamp it back.
                    rec.id = db.lastInsertedRowID
                }
                return rec
            }
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    public func fetchAll(
        includeDeleted: Bool = false,
        pinnedFirst: Bool = true
    ) async throws -> [Recording] {
        try await dbQueue.read { db in
            var request = Recording.all()
            if !includeDeleted {
                request = request.filter(Recording.Columns.deletedAt == nil)
            }
            if pinnedFirst {
                request = request
                    .order(
                        Recording.Columns.pinned.desc,
                        Recording.Columns.startedAt.desc
                    )
            } else {
                request = request.order(Recording.Columns.startedAt.desc)
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchByWavPath(_ wavPath: String) async throws -> Recording? {
        try await dbQueue.read { db in
            try Recording.filter(Recording.Columns.wavPath == wavPath).fetchOne(db)
        }
    }

    public func rename(id: Int64, title: String?) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.title.set(to: title),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func setPinned(id: Int64, pinned: Bool) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.pinned.set(to: pinned),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func softDelete(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.deletedAt.set(to: Date()),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    public func restore(id: Int64) async throws {
        try await dbQueue.write { db in
            let count = try Recording.filter(key: id).updateAll(
                db,
                [
                    Recording.Columns.deletedAt.set(to: nil),
                    Recording.Columns.updatedAt.set(to: Date()),
                ]
            )
            guard count > 0 else { throw StoreError.notFound }
        }
    }

    // MARK: - Search (FTS5)

    /// Full-text search across title and transcript_text. Empty query returns fetchAll().
    public func search(
        query: String,
        includeDeleted: Bool = false
    ) async throws -> [Recording] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await fetchAll(includeDeleted: includeDeleted)
        }

        return try await dbQueue.read { db in
            // Wrap in an FTS5 pattern that does prefix matching per token.
            let tokens = trimmed
                .split(separator: " ")
                .map { "\($0)*" }
                .joined(separator: " ")

            let sql: String
            if includeDeleted {
                sql = """
                    SELECT recordings.* FROM recordings
                    JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                    WHERE recordings_fts MATCH ?
                    ORDER BY recordings.pinned DESC, recordings.started_at DESC
                """
            } else {
                sql = """
                    SELECT recordings.* FROM recordings
                    JOIN recordings_fts ON recordings_fts.rowid = recordings.id
                    WHERE recordings_fts MATCH ? AND recordings.deleted_at IS NULL
                    ORDER BY recordings.pinned DESC, recordings.started_at DESC
                """
            }

            return try Recording.fetchAll(db, sql: sql, arguments: [tokens])
        }
    }

    // MARK: - Observation

    /// AsyncStream that re-emits the full list of (non-deleted, pinned-first)
    /// recordings on any insert/update/delete. Backed by GRDB's ValueObservation.
    public nonisolated func observeAll(pinnedFirst: Bool = true) -> AsyncStream<[Recording]> {
        let (stream, cont) = AsyncStream<[Recording]>.makeStream()
        let obs = ValueObservation.tracking { db -> [Recording] in
            var request = Recording.filter(Recording.Columns.deletedAt == nil)
            if pinnedFirst {
                request = request.order(
                    Recording.Columns.pinned.desc,
                    Recording.Columns.startedAt.desc
                )
            } else {
                request = request.order(Recording.Columns.startedAt.desc)
            }
            return try request.fetchAll(db)
        }

        // `nonisolated(unsafe)` because GRDB's DatabaseCancellable isn't Sendable
        // and it's captured by the Sendable onTermination closure below.
        // Safe: the closure only runs on stream teardown; cancellable is read-only there.
        nonisolated(unsafe) let cancellable = obs.start(
            in: dbQueue,
            onError: { _ in cont.finish() },
            onChange: { value in cont.yield(value) }
        )

        cont.onTermination = { _ in cancellable.cancel() }
        return stream
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingStoreTests 2>&1 | tail -20
```

Expected: all 8 tests pass.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 65 tests in 25 suites (57 prior + 8 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcStore/RecordingStore.swift Tests/HarcStoreTests/RecordingStoreTests.swift
git commit -m "feat: RecordingStore with CRUD + FTS5 search + ValueObservation"
```

---

### Task 3: `RecordingIngestor` — filesystem → DB on launch

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcStore/RecordingIngestor.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcStoreTests/RecordingIngestorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import HarcStore

@Suite("RecordingIngestor")
struct RecordingIngestorTests {
    private func tempBase() throws -> URL {
        // macOS canonicalizes /tmp -> /private/tmp when FileManager reads directory
        // contents. Use /private/tmp directly so wavPath comparisons match.
        let base = URL(fileURLWithPath: "/private/tmp/harc-ing-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func fakeRecording(
        base: URL, year: String, day: String, time: String,
        txt: String? = "hello world"
    ) throws -> URL {
        let dir = base.appendingPathComponent(year).appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("\(time).wav")
        try Data([0]).write(to: wav)
        if let txt {
            try txt.write(to: dir.appendingPathComponent("\(time).txt"), atomically: true, encoding: .utf8)
        }
        return wav
    }

    @Test("ingestAll inserts all WAVs not yet in the store")
    func ingestInsertsMissing() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00")
        _ = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "11-30-15")

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        let inserted = try await ingestor.ingestAll()
        #expect(inserted == 2)

        let all = try await store.fetchAll()
        #expect(all.count == 2)
    }

    @Test("ingestAll skips WAVs already in the store")
    func skipsExisting() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = try fakeRecording(base: base, year: "2026", day: "2026-04-17", time: "10-00-00")

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        _ = try await ingestor.ingestAll()
        let secondRun = try await ingestor.ingestAll()
        #expect(secondRun == 0)

        let all = try await store.fetchAll()
        #expect(all.count == 1)
        #expect(all[0].wavPath == wav.path)
    }

    @Test("ingested rows pick up transcript text from the .txt sibling")
    func ingestCapturesTranscript() async throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try fakeRecording(
            base: base, year: "2026", day: "2026-04-17", time: "10-00-00",
            txt: "discussing the Q3 roadmap"
        )

        let store = try await RecordingStore.inMemory()
        let ingestor = RecordingIngestor(baseDirectory: base, store: store)
        _ = try await ingestor.ingestAll()
        let all = try await store.fetchAll()
        #expect(all[0].transcriptText?.contains("Q3 roadmap") == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingIngestorTests 2>&1 | tail -10
```

Expected: `RecordingIngestor` not found.

- [ ] **Step 3: Write `Sources/HarcStore/RecordingIngestor.swift`**

```swift
import Foundation

/// Scans a destination folder and upserts any WAVs not already in the store.
/// Designed to run once on app startup; cheap for modest library sizes.
public struct RecordingIngestor: Sendable {
    public let baseDirectory: URL
    public let store: RecordingStore

    public init(baseDirectory: URL, store: RecordingStore) {
        self.baseDirectory = baseDirectory
        self.store = store
    }

    /// Walks the YYYY/YYYY-MM-DD/*.wav hierarchy. For each WAV not yet in the
    /// store, inserts a row with text from its `.txt` sibling (if present).
    /// Returns the number of new rows inserted.
    @discardableResult
    public func ingestAll() async throws -> Int {
        let fm = FileManager.default
        guard let yearDirs = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var inserted = 0
        for yearDir in yearDirs where isDirectory(yearDir) {
            guard let dayDirs = try? fm.contentsOfDirectory(
                at: yearDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for dayDir in dayDirs where isDirectory(dayDir) {
                guard let files = try? fm.contentsOfDirectory(
                    at: dayDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }

                for wav in files where wav.pathExtension.lowercased() == "wav" {
                    if try await store.fetchByWavPath(wav.path) != nil { continue }

                    let stem = wav.deletingPathExtension().lastPathComponent
                    let parent = wav.deletingLastPathComponent()
                    let txt = parent.appendingPathComponent("\(stem).txt")
                    let json = parent.appendingPathComponent("\(stem).json")

                    let txtExists = fm.fileExists(atPath: txt.path)
                    let jsonExists = fm.fileExists(atPath: json.path)

                    let transcriptText: String? = txtExists
                        ? (try? String(contentsOf: txt, encoding: .utf8))
                        : nil

                    let startedAt = parseStartedAt(
                        day: dayDir.lastPathComponent,
                        time: stem
                    ) ?? fileCreated(url: wav)

                    let recording = Recording(
                        wavPath: wav.path,
                        txtPath: txtExists ? txt.path : nil,
                        jsonPath: jsonExists ? json.path : nil,
                        startedAt: startedAt,
                        transcriptText: transcriptText
                    )
                    _ = try await store.upsert(recording)
                    inserted += 1
                }
            }
        }
        return inserted
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// "2026-04-17" + "10-00-00" → Date, in local time zone.
    private func parseStartedAt(day: String, time: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: "\(day) \(time)")
    }

    private func fileCreated(url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? Date()
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter RecordingIngestorTests 2>&1 | tail -15
```

Expected: 3 tests pass.

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 68 tests in 26 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcStore/RecordingIngestor.swift Tests/HarcStoreTests/RecordingIngestorTests.swift
git commit -m "feat: RecordingIngestor upserts filesystem recordings into RecordingStore"
```

---

### Task 4: Swap `RecordingsIndex` → `RecordingStore` in the popover

Replaces Plan 5's `RecordingsIndex` (filesystem scanner + `@Published` array) with a new view model that reads from `RecordingStore`. Deletes `RecordingsIndex`, rewires AppDelegate and `RecentRecordingsView`.

**Files:**
- Delete: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingsIndex.swift`
- Delete: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/RecordingsIndexTests.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingsViewModel.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecentRecordingsView.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PopoverRootView.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Delete the old files**

```bash
cd /Users/jlane/GitHub/Harc
git rm Sources/HarcUI/RecordingsIndex.swift
git rm Tests/HarcUITests/RecordingsIndexTests.swift
```

- [ ] **Step 2: Write `Sources/HarcUI/RecordingsViewModel.swift`**

```swift
import Foundation
import Combine
import HarcStore

/// View model surfacing the current list of recordings from `RecordingStore`.
/// Plan 5's `RecordingsIndex` is superseded by this class.
@MainActor
public final class RecordingsViewModel: ObservableObject {
    @Published public private(set) var recordings: [Recording] = []

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self, store] in
            guard let self else { return }
            for await list in store.observeAll(pinnedFirst: true) {
                await MainActor.run { self.recordings = list }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Non-observed one-shot refresh — useful after a direct DB mutation that should
    /// surface immediately without waiting for the ValueObservation callback.
    public func refresh() async {
        do {
            let latest = try await store.fetchAll()
            self.recordings = latest
        } catch {
            // Keep the previous list on error.
        }
    }

    public func delete(id: Int64) async throws {
        try await store.softDelete(id: id)
    }

    public func rename(id: Int64, title: String?) async throws {
        try await store.rename(id: id, title: title)
    }

    public func togglePin(id: Int64, currentlyPinned: Bool) async throws {
        try await store.setPinned(id: id, pinned: !currentlyPinned)
    }
}
```

- [ ] **Step 3: Rewrite `Sources/HarcUI/RecentRecordingsView.swift`**

```swift
import SwiftUI
import HarcStore

public struct RecentRecordingsView: View {
    @EnvironmentObject private var vm: RecordingsViewModel

    let onOpen: (Recording) -> Void

    public init(onOpen: @escaping (Recording) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("Recent")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1.2)

            if vm.recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.recordings.prefix(8)) { rec in
                            row(for: rec)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var emptyState: some View {
        Text("No recordings yet. Press Start Recording to begin.")
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurfaceVariant)
            .padding(.vertical, HarcDesign.Space.sm)
    }

    private func row(for rec: Recording) -> some View {
        Button { onOpen(rec) } label: {
            HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
                Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(rec.pinned ? Color.harcTertiary : Color.harcPrimary)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.displayTitle)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    if !rec.preview.isEmpty {
                        Text(rec.preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .lineLimit(2)
                    } else {
                        Text("(no transcript)")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.vertical, HarcDesign.Space.xs)
            .padding(.horizontal, HarcDesign.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Update `Sources/HarcUI/PopoverRootView.swift`**

Change `onOpen: (RecordingEntry) -> Void` to `onOpen: (Recording) -> Void` and update the environment/import:

```swift
import SwiftUI
import HarcStore

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var vm: RecordingsViewModel

    let onToggle: () -> Void
    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(onToggle: onToggle, onOpenSettings: onOpenSettings)
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
    }
}
```

- [ ] **Step 5: Update `HarcApp/AppDelegate.swift`**

Replace the `RecordingsIndex` integration with `RecordingStore` + `RecordingsViewModel`. Full changes:

Add import at the top:
```swift
import HarcStore
```

Change the existing `private lazy var recordingsIndex = ...` line to:
```swift
    private var store: RecordingStore?
    private var recordingsVM: RecordingsViewModel?
```

Also update the `detailWindows` type since `RecordingEntry` is gone — key by `wavPath: String` now:
```swift
    private var detailWindows: [String: TranscriptionDetailWindowController] = [:]
```

At the top of `applicationDidFinishLaunching`, ADD a Task that bootstraps the store:
```swift
        Task { [weak self] in
            await self?.bootstrapStore()
        }
```

Add the new method `bootstrapStore()` near the bottom:
```swift
    private func bootstrapStore() async {
        do {
            let store = try await RecordingStore.onDisk()
            self.store = store

            // Ingest existing filesystem recordings.
            let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
            _ = try? await ingestor.ingestAll()

            let vm = RecordingsViewModel(store: store)
            vm.start()
            self.recordingsVM = vm

            // Mount into SwiftUI environment.
            await refreshPopoverRoot()
        } catch {
            FileHandle.standardError.write(Data(
                "harc: store init failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    private func refreshPopoverRoot() async {
        guard let vm = recordingsVM, let pop = popover else { return }
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] rec in
                self?.openDetail(for: rec)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        .environmentObject(state)
        .environmentObject(vm)
        .environmentObject(prefs)

        pop.contentViewController = NSHostingController(rootView: root)
    }
```

Update `openDetail(for:)` to take a `Recording`:
```swift
    private func openDetail(for recording: Recording) {
        if let existing = detailWindows[recording.wavPath] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = TranscriptionDetailWindowController(
            recording: recording,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.wavPath)])
            },
            onDelete: { [weak self] in
                self?.deleteRecording(recording: recording)
            }
        )
        detailWindows[recording.wavPath] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deleteRecording(recording: Recording) {
        guard let id = recording.id, let vm = recordingsVM else { return }
        Task {
            try? await vm.delete(id: id)
        }
        // Also trash the files on disk.
        let fm = FileManager.default
        let paths = [recording.wavPath, recording.txtPath, recording.jsonPath].compactMap { $0 }
        for path in paths {
            try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        detailWindows[recording.wavPath]?.close()
        detailWindows.removeValue(forKey: recording.wavPath)
    }
```

REMOVE the old `recordingsIndex.refresh()` calls — the VM's ValueObservation handles refresh automatically. Search AppDelegate for `recordingsIndex` and delete every reference.

- [ ] **Step 6: Update `Sources/HarcUI/TranscriptionDetailView.swift` + controller to take `Recording`**

In `TranscriptionDetailView`:
- Change the parameter `entry: RecordingEntry` to `recording: Recording`.
- Use `recording.displayTitle` for the header.
- Use `recording.wavPath` / `recording.txtPath` / `recording.jsonPath` directly (they're `String` not `URL`).
- Read transcript from `recording.transcriptText` (cached in DB) first; fall back to reading `recording.txtPath` file if nil.

Full rewrite:

```swift
import SwiftUI
import AppKit
import HarcStore

public struct TranscriptionDetailView: View {
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var transcript: String = ""
    @State private var loadError: String? = nil
    @State private var deleteConfirm = false

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text(recording.displayTitle)
                        .font(HarcDesign.Font.titleLg)
                        .foregroundStyle(Color.harcOnSurface)
                    Text(URL(fileURLWithPath: recording.wavPath).lastPathComponent)
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                Spacer()
                toolbar
            }

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

    private var toolbar: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
            }
            .disabled(transcript.isEmpty)

            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }

            Button(role: .destructive) {
                deleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .alert("Delete recording?", isPresented: $deleteConfirm) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The recording's audio, transcript, and JSON files are moved to Trash and the entry is soft-deleted from the library.")
            }
        }
    }

    private func load() {
        if let cached = recording.transcriptText, !cached.isEmpty {
            transcript = cached
            return
        }
        guard let txtPath = recording.txtPath else {
            loadError = "No transcript file — recording likely had no transcription."
            return
        }
        do {
            transcript = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
        } catch {
            loadError = "Failed to load transcript: \(error.localizedDescription)"
        }
    }
}
```

And update `HarcApp/WindowControllers/TranscriptionDetailWindowController.swift`:

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
        onDelete: @escaping () -> Void
    ) {
        let root = TranscriptionDetailView(recording: recording, onReveal: onReveal, onDelete: onDelete)
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

Also: because Plan 4's `RecordingSession.stop()` writes a recording to disk but our UI now reads from the DB, we need to upsert the new recording into the store after stop. Find `stopRecording()` in AppDelegate. After `state.markStopped(...)`, ADD:

```swift
            if let store = self.store {
                let startedAt = result.wavURL.startedAtFromHarcPath() ?? Date()
                let transcriptText = result.txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                let rec = Recording(
                    wavPath: result.wavURL.path,
                    txtPath: result.txtURL?.path,
                    jsonPath: result.jsonURL?.path,
                    startedAt: startedAt,
                    endedAt: Date(),
                    transcriptText: transcriptText
                )
                _ = try? await store.upsert(rec)
            }
```

Define the helper `URL.startedAtFromHarcPath` in a small Swift file at `HarcApp/URL+HarcPath.swift`:
```swift
import Foundation

extension URL {
    /// If this URL matches the Harc layout `.../YYYY-MM-DD/HH-mm-ss.wav`, parse
    /// the date + time into a Date in the current locale.
    func startedAtFromHarcPath() -> Date? {
        let day = self.deletingLastPathComponent().lastPathComponent
        let time = self.deletingPathExtension().lastPathComponent
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: "\(day) \(time)")
    }
}
```

Create this file via: `mkdir -p /Users/jlane/GitHub/Harc/HarcApp && cat > ...`. xcodegen picks it up automatically.

- [ ] **Step 7: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: clean build. 65 tests pass (8 RecordingStoreTests + 3 MigrationTests + 3 RecordingIngestorTests + 51 pre-Plan-6 after removing RecordingsIndex's 3 tests = 65). If the arithmetic differs, just check swift test output is green.

- [ ] **Step 8: Smoke test — verify popover still works end-to-end**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
sleep 3
ls ~/Library/Application\ Support/Harc/Harc.db 2>&1
```

Expected: `Harc.db` exists at `~/Library/Application Support/Harc/Harc.db` (created on first launch with bootstrapped store). Popover shows the Recent list populated from the DB (with any existing WAVs ingested on launch).

Kill with `pkill -x Harc`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: swap RecordingsIndex for RecordingStore + RecordingsViewModel in popover"
```

This commit deletes 2 files, adds 1 new (RecordingsViewModel), and modifies 5 (RecentRecordingsView, PopoverRootView, AppDelegate, TranscriptionDetailView, TranscriptionDetailWindowController). ~8 files total.

---

### Task 5: Library window with search

A dedicated NSWindow showing the full recordings list with a search bar at top. Opened from the popover's `⋯` menu.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryViewModel.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibrarySearchField.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift`
- Create: `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/LibraryWindowController.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/RecordingControlsView.swift` (adds Library menu item)
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/PopoverRootView.swift` (threads onOpenLibrary)
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift` (opens library window)

- [ ] **Step 1: Write `Sources/HarcUI/LibraryViewModel.swift`**

```swift
import Foundation
import Combine
import HarcStore

/// Library-window view model. Debounces search queries and fetches results.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var searchText: String = ""
    @Published public private(set) var recordings: [Recording] = []

    public let store: RecordingStore
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        // Debounce search changes to 200ms.
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] value in
                self?.performSearch(value)
            }
            .store(in: &cancellables)

        // Baseline: observe the store when search is empty.
        observationTask = Task { [weak self, store] in
            guard let self else { return }
            for await list in store.observeAll(pinnedFirst: true) {
                await MainActor.run {
                    if self.searchText.isEmpty {
                        self.recordings = list
                    }
                }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        searchTask?.cancel()
        cancellables.removeAll()
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self, store] in
            guard let self else { return }
            do {
                if trimmed.isEmpty {
                    let all = try await store.fetchAll()
                    await MainActor.run { self.recordings = all }
                } else {
                    let results = try await store.search(query: trimmed)
                    await MainActor.run { self.recordings = results }
                }
            } catch {
                // Keep previous list on error.
            }
        }
    }

    // MARK: Actions (pass-through to store)

    public func rename(id: Int64, title: String?) async throws {
        try await store.rename(id: id, title: title)
    }

    public func togglePin(id: Int64, currentlyPinned: Bool) async throws {
        try await store.setPinned(id: id, pinned: !currentlyPinned)
    }

    public func delete(id: Int64) async throws {
        try await store.softDelete(id: id)
    }
}
```

- [ ] **Step 2: Write `Sources/HarcUI/LibrarySearchField.swift`**

```swift
import SwiftUI

public struct LibrarySearchField: View {
    @Binding var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.harcOnSurfaceVariant)
            TextField("Search recordings…", text: $text)
                .textFieldStyle(.plain)
                .font(HarcDesign.Font.bodyMd)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HarcDesign.Space.sm)
        .padding(.vertical, HarcDesign.Space.xs)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous))
    }
}
```

- [ ] **Step 3: Write `Sources/HarcUI/LibraryWindowRootView.swift`**

```swift
import SwiftUI
import AppKit
import HarcStore

public struct LibraryWindowRootView: View {
    @EnvironmentObject private var vm: LibraryViewModel

    let onOpen: (Recording) -> Void

    public init(onOpen: @escaping (Recording) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            LibrarySearchField(text: $vm.searchText)
            list
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    @ViewBuilder
    private var list: some View {
        if vm.recordings.isEmpty {
            VStack {
                Spacer()
                Text(vm.searchText.isEmpty ? "No recordings yet." : "No matches.")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Spacer()
            }
        } else {
            List(vm.recordings) { rec in
                row(for: rec)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(rec) }
                    .contextMenu {
                        Button("Open") { onOpen(rec) }
                        Button(rec.pinned ? "Unpin" : "Pin") {
                            Task { try? await vm.togglePin(id: rec.id ?? -1, currentlyPinned: rec.pinned) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { try? await vm.delete(id: rec.id ?? -1) }
                        } label: {
                            Text("Delete")
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private func row(for rec: Recording) -> some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                .foregroundStyle(rec.pinned ? Color.harcTertiary : Color.harcPrimary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.displayTitle)
                    .font(HarcDesign.Font.titleSm)
                    .foregroundStyle(Color.harcOnSurface)
                if !rec.preview.isEmpty {
                    Text(rec.preview)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }
}
```

- [ ] **Step 4: Write `HarcApp/WindowControllers/LibraryWindowController.swift`**

```swift
import AppKit
import SwiftUI
import HarcUI
import HarcStore

@MainActor
final class LibraryWindowController: NSWindowController {
    convenience init(vm: LibraryViewModel, onOpen: @escaping (Recording) -> Void) {
        let root = LibraryWindowRootView(onOpen: onOpen)
            .environmentObject(vm)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
        self.init(window: window)
    }
}
```

- [ ] **Step 5: Update `Sources/HarcUI/RecordingControlsView.swift`** to pass a Library menu item through

Change the `header` menu to include a Library entry. Find the existing `Menu { Button("Settings…", ...) Divider() Button("Quit Harc") ... }` block and REPLACE with:

```swift
            Menu {
                Button("Open Library…", action: onOpenLibrary)
                Button("Settings…", action: onOpenSettings)
                Divider()
                Button("Quit Harc") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Color.harcOnSurfaceVariant)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
```

Add a new initializer parameter `onOpenLibrary: () -> Void`:
```swift
    let onToggle: () -> Void
    let onOpenSettings: () -> Void
    let onOpenLibrary: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpenSettings = onOpenSettings
        self.onOpenLibrary = onOpenLibrary
    }
```

- [ ] **Step 6: Update `Sources/HarcUI/PopoverRootView.swift`** — thread `onOpenLibrary`

```swift
import SwiftUI
import HarcStore

public struct PopoverRootView: View {
    @EnvironmentObject private var state: RecordingState
    @EnvironmentObject private var vm: RecordingsViewModel

    let onToggle: () -> Void
    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void
    let onOpenLibrary: () -> Void

    public init(
        onToggle: @escaping () -> Void,
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
        self.onOpenLibrary = onOpenLibrary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            RecordingControlsView(
                onToggle: onToggle,
                onOpenSettings: onOpenSettings,
                onOpenLibrary: onOpenLibrary
            )
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            RecentRecordingsView(onOpen: onOpen)
        }
        .padding(HarcDesign.Space.lg)
        .frame(width: 400)
    }
}
```

- [ ] **Step 7: Update `HarcApp/AppDelegate.swift`**

Add state:
```swift
    private var libraryWindow: LibraryWindowController?
    private var libraryVM: LibraryViewModel?
```

In `refreshPopoverRoot()`, pass the new `onOpenLibrary` closure:
```swift
        let root = PopoverRootView(
            onToggle: { [weak self] in
                Task { await self?.toggleRecording() }
            },
            onOpen: { [weak self] rec in
                self?.openDetail(for: rec)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onOpenLibrary: { [weak self] in
                self?.openLibrary()
            }
        )
        .environmentObject(state)
        .environmentObject(vm)
        .environmentObject(prefs)
```

Add the `openLibrary()` method:
```swift
    @objc private func openLibrary() {
        if let existing = libraryWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let store else { return }
        let vm = LibraryViewModel(store: store)
        libraryVM = vm
        let controller = LibraryWindowController(vm: vm) { [weak self] rec in
            self?.openDetail(for: rec)
        }
        libraryWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 8: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: clean, all tests pass.

- [ ] **Step 9: Rebuild + smoke**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Click the status-bar icon → popover → `⋯` → "Open Library…". A new window opens with the search bar + list. Type "test" in the search box → filters the list. Right-click a row → context menu with Open/Pin/Reveal/Delete.

Kill with `pkill -x Harc`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: Library window with search + context menu actions"
```

---

### Task 6: Inline rename + pin row actions

Adds rename and pin affordances on library rows (via the context menu) and the TranscriptionDetailView (inline rename field).

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift` (pass vm into TranscriptionDetailWindowController)
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/WindowControllers/TranscriptionDetailWindowController.swift` (take a callback for rename)

- [ ] **Step 1: Add a rename alert to `LibraryWindowRootView`**

In `LibraryWindowRootView`, add state:
```swift
    @State private var renameTarget: Recording?
    @State private var renameText: String = ""
```

In the list's `.contextMenu`, add a Rename button as the first item:
```swift
                    .contextMenu {
                        Button("Rename…") {
                            renameTarget = rec
                            renameText = rec.title ?? ""
                        }
                        Button("Open") { onOpen(rec) }
                        Button(rec.pinned ? "Unpin" : "Pin") {
                            Task { try? await vm.togglePin(id: rec.id ?? -1, currentlyPinned: rec.pinned) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { try? await vm.delete(id: rec.id ?? -1) }
                        } label: {
                            Text("Delete")
                        }
                    }
```

Add an `.alert` modifier on the outer `VStack`:
```swift
        .alert("Rename recording", isPresented: .constant(renameTarget != nil), presenting: renameTarget) { rec in
            TextField("Title", text: $renameText)
            Button("Save") {
                let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    try? await vm.rename(id: rec.id ?? -1, title: newTitle.isEmpty ? nil : newTitle)
                    renameTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { _ in
            Text("Leave empty to clear the custom title.")
        }
```

- [ ] **Step 2: Add a rename action to `TranscriptionDetailView`**

Add a `onRename: (String?) -> Void` parameter:
```swift
    let recording: Recording
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void

    @State private var renameDraft: String
    @State private var isEditingTitle = false

    public init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void
    ) {
        self.recording = recording
        self.onReveal = onReveal
        self.onDelete = onDelete
        self.onRename = onRename
        self._renameDraft = State(initialValue: recording.title ?? "")
    }
```

Replace the header's title Text with an editable version:
```swift
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
```

- [ ] **Step 3: Update `TranscriptionDetailWindowController`** to take the rename callback

```swift
    convenience init(
        recording: Recording,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void
    ) {
        let root = TranscriptionDetailView(
            recording: recording,
            onReveal: onReveal,
            onDelete: onDelete,
            onRename: onRename
        )
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
```

- [ ] **Step 4: Update `AppDelegate.openDetail(for:)`** to pass the rename callback:

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

- [ ] **Step 5: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Right-click a row in the Library → Rename → enter "Test rename" → Save → row updates to show new title. Click Pin → icon flips to pin, row moves to top. In detail window, click the title → it becomes editable → enter new text → press Enter → saves.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rename + pin actions via context menu + inline title editor"
```

---

### Task 7: `FrontmostAppPaster` — copy + auto-paste into frontmost app

Adds a "Paste into frontmost app" button that copies the transcript to the clipboard and synthesizes ⌘V into whatever app had focus before Harc.

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/FrontmostAppPaster.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift` (add button)
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/Harc.entitlements` (add automation entitlement — via project.yml)

- [ ] **Step 1: Write `Sources/HarcUI/FrontmostAppPaster.swift`**

```swift
import AppKit
import Carbon.HIToolbox
@preconcurrency import ApplicationServices  // Swift-6 strict: `kAXTrustedCheckOptionPrompt`

/// Writes text to the clipboard and synthesises Cmd-V into the frontmost
/// application. Requires Accessibility permission (Input Monitoring works too
/// for some event types, but CGEvent post for synthetic keystrokes needs
/// Accessibility on modern macOS).
public enum FrontmostAppPaster {
    public enum PasteError: Error, LocalizedError {
        case accessibilityDenied
        case noFrontmostApp
        case eventCreationFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Harc needs Accessibility permission to paste into other apps. Grant it in System Settings → Privacy & Security → Accessibility."
            case .noFrontmostApp:
                return "No frontmost application to paste into."
            case .eventCreationFailed:
                return "Failed to synthesize the paste keystroke."
            }
        }
    }

    /// Copy `text` to the clipboard and paste into the frontmost app.
    /// `dwellMs` is the delay before the paste fires — gives macOS a moment to
    /// restore focus to the previous app after our window resigns key.
    public static func copyAndPaste(_ text: String, dwellMs: UInt64 = 150) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Resign key so focus returns to whatever was frontmost before us.
        NSApp.hide(nil)

        // Small delay, then synthesize ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(dwellMs))) {
            _ = try? synthesizeCmdV()
        }
    }

    /// Synthesize Cmd-V into the frontmost (post-hide) application.
    public static func synthesizeCmdV() throws {
        // AXIsProcessTrustedWithOptions with the prompt flag asks the user
        // to grant Accessibility if it hasn't been granted yet.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            throw PasteError.accessibilityDenied
        }

        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            throw PasteError.eventCreationFailed
        }
        // V = key code 9.
        let vKey: CGKeyCode = 9
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { throw PasteError.eventCreationFailed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Just copy — no paste synthesis.
    public static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Add a "Paste" button to `TranscriptionDetailView.toolbar`**

Add to the `toolbar` HStack, between Copy and Reveal:

```swift
            Button {
                try? FrontmostAppPaster.copyAndPaste(transcript)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("Copy to clipboard and paste into the frontmost app")
```

- [ ] **Step 3: Update `project.yml`** — no entitlement needed; Accessibility is a TCC prompt at runtime.

Verify `com.apple.security.cs.disable-library-validation` is already in the entitlements from Plan 1/2. No additional entitlement required.

- [ ] **Step 4: Build + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
APP=$(xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Harc.app
xattr -cr "$APP" 2>/dev/null
open "$APP"
```

Manual smoke:
1. Open a text field in another app (TextEdit, Notes, etc).
2. Open Harc popover → click a Recent recording.
3. In the detail window, click "Paste".
4. macOS prompts for Accessibility permission on first use — grant it.
5. The window hides, focus returns to the other app, ⌘V fires, transcript pastes.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: FrontmostAppPaster + Paste button in TranscriptionDetailView"
```

---

### Task 8: Polish — gitignore Info.plist, reactive destination, subscription task cancel

Wraps up deferred items from Plan 5.

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/.gitignore`
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Add `HarcApp/Info.plist` to `.gitignore`**

Append to `.gitignore`:
```
# xcodegen-generated
HarcApp/Info.plist
```

- [ ] **Step 2: Make the live-preview subscription Task cancellable**

Add state to AppDelegate:
```swift
    private var previewTask: Task<Void, Never>?
```

In `startRecording()`, replace the existing `Task { [weak self, transcriber] in for await update in await transcriber.updates ... }` block with:
```swift
            self.previewTask?.cancel()
            self.previewTask = Task { [weak self, transcriber] in
                for await update in await transcriber.updates {
                    await MainActor.run {
                        self?.state.appendPreview(update.joinedTextSoFar)
                    }
                }
            }
```

In `stopRecording()`, after `self.session = nil` (but while the session is still being torn down), add:
```swift
        previewTask?.cancel()
        previewTask = nil
```

(Put this after the `do { ... } catch { ... }` block, before `resetAfterFailure()`.)

- [ ] **Step 3: React to destination-path preference changes**

After `bootstrapStore()` finishes, ADD an observer that re-ingests if the destination changes. Near `bootstrapStore`, add:

```swift
    private var prefsObserver: AnyCancellable?

    private func observeDestinationChanges() {
        prefsObserver = prefs.$destinationPath
            .removeDuplicates()
            .dropFirst()  // skip initial value
            .sink { [weak self] _ in
                Task { await self?.reingestForNewDestination() }
            }
    }

    private func reingestForNewDestination() async {
        guard let store = store else { return }
        let ingestor = RecordingIngestor(baseDirectory: prefs.destinationURL, store: store)
        _ = try? await ingestor.ingestAll()
    }
```

Call `observeDestinationChanges()` inside `bootstrapStore()` after the VM is attached:
```swift
        self.recordingsVM = vm
        observeDestinationChanges()
```

Add to the import list:
```swift
import Combine
```

- [ ] **Step 4: Rename `resetAfterFailure` → `resetUI`**

Find `resetAfterFailure()` in AppDelegate. Rename to `resetUI()` and remove the misleading `if state.isRecording { state.markStopped(...) }` branch (we can just check `session != nil`):

```swift
    private func resetUI() {
        session = nil
        updateMenuBarIcon(recording: false)
    }
```

And update all call sites: `resetAfterFailure()` → `resetUI()`. Three places: the `catch` in `startRecording`, the end of `stopRecording`, and any other.

- [ ] **Step 5: Build + test + smoke**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: clean build, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: gitignore Info.plist; cancel preview task on stop; react to dest change; rename resetUI"
```

---

## Acceptance Criteria (Plan 6 complete when all true)

- `swift test` passes all existing + new HarcStoreTests. Expect ~68 tests in ~26 suites.
- `swift build` clean; `swift build -Xswiftc -strict-concurrency=complete` clean.
- `xcodegen generate && xcodebuild ... build` succeeds; `codesign --verify --deep --strict Harc.app` green.
- Launching `Harc.app` creates `~/Library/Application Support/Harc/Harc.db` on first run and ingests any existing WAVs from `~/Documents/Harc/`.
- The popover Recent list is populated from the DB (not filesystem).
- The `⋯` menu has an "Open Library…" entry that opens a new window with a search bar + full list.
- Typing in the search bar filters the library by title + transcript text.
- Right-click a library row → context menu: Rename, Open, Pin/Unpin, Reveal, Delete.
- Rename updates the DB + UI; pin moves the row to the top.
- Soft-deleted recordings disappear from the library but aren't erased from disk (just moved to Trash).
- TranscriptionDetailView has an editable title (click the title → type → Enter), plus a "Paste" button that copies + synthesizes ⌘V into the frontmost app.
- `HarcApp/Info.plist` is gitignored.
- 8 new commits on `main`.

## Open Decisions

- **Search relevance / BM25 ranking** — FTS5 has BM25 built in. Our queries don't use it (just prefix match + date-desc sort). If search quality feels poor, switch the ORDER BY clause to `bm25(recordings_fts) ASC, pinned DESC, started_at DESC`.
- **DB location** — currently `~/Library/Application Support/Harc/Harc.db`. Standard macOS convention. If we ever support multiple Harc profiles (unlikely for a personal recording tool), this would need to shift.
- **Trash UI** — soft-deleted recordings are hidden but not restorable from the UI. A "Show deleted" toggle in the Library search bar could surface them. Plan 7+ polish.

## Self-Review

**Spec coverage (Plan 1's Plan 6 sketch):**
- "GRDB + SQLite at `~/Library/Application Support/Harc/Harc.db`" → Task 1 + Task 2.
- "Schema: recordings(...) with FTS5 virtual table" → Task 1.
- "CRUD + full-text search surfaced in the Library view" → Tasks 2, 5.
- "Copy to NSPasteboard; Paste via CGEvent injection (Accessibility permission)" → Task 7.
- "Renaming, pinning, soft-deletion" → Task 6.
- "Reveal in Finder opens the destination-folder hierarchy" → already in TranscriptionDetailView from Plan 5; Task 4 preserves it, Task 5 adds it to Library context menu.
- "Tests: schema migrations, FTS ranking sanity, paste-to-frontmost simulated" → migrations + FTS covered; paste simulation is manual.

**Placeholder scan:** none. Every code block is complete.

**Type consistency:**
- `Recording` (T1) flows through `RecordingStore` (T2), `RecordingIngestor` (T3), `RecordingsViewModel` + `LibraryViewModel` (T4, T5), all views (T4, T5, T6), and `TranscriptionDetailWindowController` (T6).
- `RecordingEntry` is fully deleted in Task 4; nothing later references it.
- `RecordingsIndex` is deleted in Task 4.
- `FrontmostAppPaster` is a plain enum namespace, consumed only by TranscriptionDetailView (T7).
- AppDelegate's window caches are keyed by `String` (wavPath) post-Task-4 (not `URL` like Plan 5).
