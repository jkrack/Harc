# Custom Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a user-editable `{ from, to }` replacement list that rewrites every newly-transcribed transcript (chunks, joined text, `.txt`, `.json`, SQLite row, pasteboard) using case-insensitive, word-boundary-aware string replacement. Lives in the **Processing** tab of Settings. Spec: `docs/superpowers/specs/2026-04-19-custom-vocabulary-design.md`.

**Architecture:** Storage in `HarcPreferences` (UserDefaults, JSON-encoded `Vocabulary`). Core in `HarcClient/VocabularyReplacer.swift`. Hooked at two points in `ChunkedTranscriber`: after each `ChunkResult` is built, and once more on the assembled `joinedText` at finalize. UI is a new `ProcessingSettingsView` inside a new tabs scaffold.

**Tech Stack:** Swift 6, SwiftUI (Form / Table / TextField), Foundation (`NSRegularExpression`), UserDefaults.

**Prerequisites:**
- The Settings tabs scaffold does not exist yet. Task 0 builds it. If a concurrent branch has already landed tabs, skip Task 0 and jump to Task 1; merge-resolve the Processing tab insertion point.

---

### Task 0 (PREREQUISITE): Settings tabs scaffold

**Effort:** M

**Depends on:** none

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/SettingsView.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/GeneralSettingsView.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/RecordingSettingsView.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/LibrarySettingsView.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/ProcessingSettingsView.swift` (empty placeholder — body filled in Task 5)

- [ ] **Step 1: Create the four tab view files.** Each is a `public struct` conforming to `View` with an `EnvironmentObject` on `HarcPreferences` and a `Form { … }` body.

Move the existing `SettingsView` content into the appropriate tabs:
- **General** — (empty in v1; reserved for launch-at-login, appearance, etc. Show a placeholder "Coming soon" row or just a summary card.)
- **Recording** — Destination folder, Chunk duration, Global hotkey, Speech recognition model card, Privacy footer.
- **Library** — (empty in v1.)
- **Processing** — Diarization toggle (currently in Recording-ish territory; put it here since it's a processing decision) + the Vocabulary UI (stub in Task 0, filled in Task 5).

- [ ] **Step 2: Refactor `SettingsView` into a `TabView` wrapper.**

```swift
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "mic") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "tray.full") }
            ProcessingSettingsView()
                .tabItem { Label("Processing", systemImage: "wand.and.rays") }
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 560, minHeight: 440)
    }
}
```

- [ ] **Step 3: Verify via xcodegen + build.**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED. Open the Settings window manually — four tabs render, Recording tab has the full existing UI, Processing tab has a placeholder.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/SettingsView.swift Sources/HarcUI/Settings/
git commit -m "refactor: Settings into tabs (General / Recording / Library / Processing)"
```

---

### Task 1: `VocabularyEntry` + `Vocabulary` types + HarcPreferences storage

**Effort:** S

**Depends on:** none (independent of Task 0)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcCore/Vocabulary.swift`
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/HarcPreferences.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcUITests/HarcPreferencesTests.swift` (new file if missing)

**Rationale for placing types in HarcCore:** both HarcClient (the replacer) and HarcUI (the editor) need to read these types. HarcCore is the shared leaf dependency — no cycles.

- [ ] **Step 1: Create the Vocabulary types in HarcCore.**

```swift
// Sources/HarcCore/Vocabulary.swift
import Foundation

public struct VocabularyEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: String
    public var to: String
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        from: String,
        to: String,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

public struct Vocabulary: Codable, Equatable, Sendable {
    public var entries: [VocabularyEntry]

    public init(entries: [VocabularyEntry] = []) {
        self.entries = entries
    }

    public static let empty = Vocabulary(entries: [])
}
```

- [ ] **Step 2: Extend `HarcPreferences`.**

Add to the `Key` enum:
```swift
static let vocabulary = "harc.vocabulary"
```

Add the property:
```swift
@Published public var vocabulary: Vocabulary {
    didSet { persistVocabulary() }
}
```

Add to `init` (AFTER the existing `self.chunkDurationSeconds = …` line):
```swift
if let data = defaults.data(forKey: Key.vocabulary),
   let decoded = try? JSONDecoder().decode(Vocabulary.self, from: data) {
    self.vocabulary = decoded
} else {
    self.vocabulary = .empty
}
```

Add mutation helpers + persistence (at end of the class):

```swift
public func addEntry(from: String, to: String) {
    var v = vocabulary
    v.entries.append(VocabularyEntry(from: from, to: to))
    vocabulary = v
}

public func updateEntry(id: VocabularyEntry.ID, from: String? = nil, to: String? = nil, enabled: Bool? = nil) {
    var v = vocabulary
    guard let idx = v.entries.firstIndex(where: { $0.id == id }) else { return }
    if let from { v.entries[idx].from = from }
    if let to { v.entries[idx].to = to }
    if let enabled { v.entries[idx].enabled = enabled }
    vocabulary = v
}

public func toggleEntry(id: VocabularyEntry.ID) {
    var v = vocabulary
    guard let idx = v.entries.firstIndex(where: { $0.id == id }) else { return }
    v.entries[idx].enabled.toggle()
    vocabulary = v
}

public func deleteEntries(ids: Set<VocabularyEntry.ID>) {
    var v = vocabulary
    v.entries.removeAll { ids.contains($0.id) }
    vocabulary = v
}

public func moveEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
    var v = vocabulary
    v.entries.move(fromOffsets: source, toOffset: destination)
    vocabulary = v
}

private func persistVocabulary() {
    if let data = try? JSONEncoder().encode(vocabulary) {
        UserDefaults.standard.set(data, forKey: Key.vocabulary)
    }
}
```

Import `HarcCore` at the top of `HarcPreferences.swift`.

- [ ] **Step 3: Add HarcCore dep to HarcUI.**

Verify `Package.swift` HarcUI target already depends on HarcCore (it does via transitive `HarcClient`/`HarcStore`, but add explicit for clarity if missing).

- [ ] **Step 4: Unit test persistence (new test file).**

```swift
// Tests/HarcUITests/HarcPreferencesTests.swift
import Testing
import Foundation
@testable import HarcUI
import HarcCore

@MainActor
struct HarcPreferencesTests {
    private func suite() -> UserDefaults {
        let name = "harc.test.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("addEntry persists across reload")
    func addEntryRoundTrip() {
        // HarcPreferences currently uses UserDefaults.standard; test via a
        // temporary name scrubbed after. Acceptable to test against .standard
        // with a cleanup, or refactor HarcPreferences to accept a defaults
        // instance. If the latter, do it as part of this task.
        let prefs = HarcPreferences()
        let startCount = prefs.vocabulary.entries.count
        prefs.addEntry(from: "Arakeet", to: "Parakeet")
        #expect(prefs.vocabulary.entries.count == startCount + 1)
        #expect(prefs.vocabulary.entries.last?.from == "Arakeet")
        #expect(prefs.vocabulary.entries.last?.to == "Parakeet")
        if let id = prefs.vocabulary.entries.last?.id {
            prefs.deleteEntries(ids: [id])
        }
    }

    @Test("toggleEntry flips enabled flag")
    func toggleEntry() {
        let prefs = HarcPreferences()
        prefs.addEntry(from: "Foo", to: "Bar")
        let id = prefs.vocabulary.entries.last!.id
        let before = prefs.vocabulary.entries.last!.enabled
        prefs.toggleEntry(id: id)
        #expect(prefs.vocabulary.entries.last!.enabled != before)
        prefs.deleteEntries(ids: [id])
    }
}
```

(Optional refactor: add a `HarcPreferences.init(defaults: UserDefaults = .standard)` overload to allow hermetic tests. Nice-to-have for v1.)

- [ ] **Step 5: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
```

Expected: clean build, new tests green, no strict-concurrency complaints.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcCore/Vocabulary.swift Sources/HarcUI/HarcPreferences.swift Tests/HarcUITests/HarcPreferencesTests.swift
git commit -m "feat: Vocabulary model + HarcPreferences persistence"
```

---

### Task 2: `VocabularyReplacer` core — word-boundary, case-aware replace

**Effort:** M

**Depends on:** Task 1 (uses `Vocabulary`/`VocabularyEntry` types)

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcClient/VocabularyReplacer.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/VocabularyReplacerTests.swift`

- [ ] **Step 1: Create `VocabularyReplacer`.**

```swift
// Sources/HarcClient/VocabularyReplacer.swift
import Foundation
import HarcCore

/// Applies a Vocabulary to a raw transcript string. Pure function —
/// no I/O, no state. Safe to call from any thread.
///
/// Semantics:
/// - Case-insensitive, word-boundary-aware (NSRegularExpression `\b`).
/// - User-typed `from` is passed through `NSRegularExpression.escapedPattern`
///   so metacharacters are literal.
/// - Supports multi-word phrases on either side.
/// - Preserves surface casing of the match: all-lower → to.lowercased,
///   all-upper → to.uppercased, Title-case → Title-case(to), mixed → to verbatim.
/// - Rules applied in entries-array order; each rule runs once per call.
/// - Disabled / empty entries are skipped.
/// - Idempotent: apply(apply(x)) == apply(x) for the common case.
public enum VocabularyReplacer {
    /// Upper bound on enabled rules compiled per call. See design doc §8.
    public static let maxEnabledRules = 500

    public static func apply(_ input: String, using vocabulary: Vocabulary) -> String {
        guard !input.isEmpty else { return input }
        var result = input
        var applied = 0
        for entry in vocabulary.entries {
            if applied >= maxEnabledRules { break }
            guard entry.enabled else { continue }
            let from = entry.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = entry.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { continue }
            result = applyOne(result, from: from, to: to)
            applied += 1
        }
        return result
    }

    private static func applyOne(_ input: String, from: String, to: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let pattern = "\\b\(escaped)\\b"
        let options: NSRegularExpression.Options = [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            FileHandle.standardError.write(Data(
                "harc-client: vocabulary rule failed to compile: \(from)\n".utf8
            ))
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        var cursor = 0
        for m in matches {
            let matched = ns.substring(with: m.range)
            let pre = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += pre
            out += casePreserved(replacement: to, matching: matched)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Applies the input's surface casing to the replacement. For multi-word
    /// phrases we only look at the first word's casing — a deliberate
    /// simplification (see design doc §6).
    static func casePreserved(replacement: String, matching match: String) -> String {
        // Key the decision off the first word of the matched substring.
        let firstWord = match.split(separator: " ").first.map(String.init) ?? match
        if firstWord == firstWord.lowercased() {
            return replacement.lowercased()
        }
        if firstWord == firstWord.uppercased() && firstWord.count > 1 {
            return replacement.uppercased()
        }
        if let first = firstWord.first, first.isUppercase,
           firstWord.dropFirst() == firstWord.dropFirst().lowercased() {
            // Title-case: capitalize first char, keep the rest as authored.
            guard let first = replacement.first else { return replacement }
            return first.uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
```

- [ ] **Step 2: Add unit tests.**

```swift
// Tests/HarcClientTests/VocabularyReplacerTests.swift
import Testing
import Foundation
@testable import HarcClient
import HarcCore

struct VocabularyReplacerTests {
    private func vocab(_ rules: [(String, String)]) -> Vocabulary {
        Vocabulary(entries: rules.map { VocabularyEntry(from: $0.0, to: $0.1) })
    }

    @Test("whole-word case-insensitive replace")
    func replacesWholeWordCaseInsensitive() {
        let v = vocab([("Arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet is up", using: v) == "Parakeet is up")
        #expect(VocabularyReplacer.apply("arakeet is up", using: v) == "parakeet is up")
        #expect(VocabularyReplacer.apply("ARAKEET is up", using: v) == "PARAKEET is up")
    }

    @Test("does not match subword")
    func doesNotMatchSubword() {
        let v = vocab([("Sara", "Sarah")])
        #expect(VocabularyReplacer.apply("Saratoga", using: v) == "Saratoga")
        #expect(VocabularyReplacer.apply("Sara went", using: v) == "Sarah went")
    }

    @Test("preserves surrounding punctuation")
    func preservesSurroundingPunctuation() {
        let v = vocab([("Arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet's tests, Arakeet.", using: v) == "Parakeet's tests, Parakeet.")
    }

    @Test("multi-word phrase matches as unit")
    func multiWordPhrase() {
        let v = vocab([("oh kay are", "OKR")])
        #expect(VocabularyReplacer.apply("the oh kay are process", using: v) == "the OKR process")
    }

    @Test("multi-word phrase with punctuation")
    func multiWordPhraseWithPunctuation() {
        let v = vocab([("oh kay are", "OKR")])
        #expect(VocabularyReplacer.apply("the oh kay are, then", using: v) == "the OKR, then")
    }

    @Test("chained rules apply in order")
    func chainedRulesApplyInOrder() {
        let v = vocab([("sara", "Sarah"), ("Sarah", "Sarah Kim")])
        #expect(VocabularyReplacer.apply("sara went home", using: v) == "Sarah Kim went home")
    }

    @Test("disabled rule is skipped")
    func disabledRuleIsSkipped() {
        var v = vocab([("Arakeet", "Parakeet")])
        v.entries[0].enabled = false
        #expect(VocabularyReplacer.apply("Arakeet", using: v) == "Arakeet")
    }

    @Test("empty vocabulary is identity")
    func emptyVocabularyIsIdentity() {
        #expect(VocabularyReplacer.apply("hello world", using: .empty) == "hello world")
    }

    @Test("empty from/to is skipped, not crashed")
    func emptyFromOrToSkipped() {
        let v = vocab([("", "Parakeet"), ("Arakeet", "")])
        #expect(VocabularyReplacer.apply("Arakeet", using: v) == "Arakeet")
    }

    @Test("idempotent: apply twice == apply once")
    func idempotent() {
        let v = vocab([("Arakeet", "Parakeet")])
        let once = VocabularyReplacer.apply("Arakeet", using: v)
        let twice = VocabularyReplacer.apply(once, using: v)
        #expect(once == twice)
    }

    @Test("regex metacharacters in `from` are literal")
    func regexMetaInFromIsLiteral() {
        let v = vocab([("C++", "Cpp")])
        #expect(VocabularyReplacer.apply("I love C++ code", using: v) == "I love Cpp code")
    }

    @Test("case preservation — lowercase stays lowercase")
    func caseLowerStaysLower() {
        let v = vocab([("arakeet", "Parakeet")])
        #expect(VocabularyReplacer.apply("arakeet is down", using: v) == "parakeet is down")
    }

    @Test("case preservation — title stays title")
    func caseTitleStaysTitle() {
        let v = vocab([("Arakeet", "parakeet")])
        #expect(VocabularyReplacer.apply("Arakeet is down", using: v) == "Parakeet is down")
    }

    @Test("case preservation — all caps stays all caps")
    func caseAllCapsStaysAllCaps() {
        let v = vocab([("arakeet", "parakeet")])
        #expect(VocabularyReplacer.apply("ARAKEET IS DOWN", using: v) == "PARAKEET IS DOWN")
    }

    @Test("unicode word boundaries — diacritics behave")
    func handlesUnicode() {
        let v = vocab([("café", "coffee")])
        #expect(VocabularyReplacer.apply("the café opens", using: v) == "the coffee opens")
    }
}
```

- [ ] **Step 3: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test --filter VocabularyReplacerTests 2>&1 | tail -15
swift test 2>&1 | tail -5
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
```

Expected: all VocabularyReplacer tests green; strict-concurrency clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcClient/VocabularyReplacer.swift Tests/HarcClientTests/VocabularyReplacerTests.swift
git commit -m "feat: VocabularyReplacer — word-boundary case-aware string rewrite"
```

---

### Task 3: Wire `VocabularyReplacer` into `ChunkedTranscriber`

**Effort:** S

**Depends on:** Task 2

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcClient/ChunkedTranscriber.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcClientTests/ChunkedTranscriberTests.swift` (append one test)

- [ ] **Step 1: Add `vocabulary` parameter to `ChunkedTranscriber.init`.**

Add stored property:
```swift
private let vocabulary: Vocabulary
```

Update init:
```swift
public init(
    client: any TranscribingClient,
    diarize: Bool = true,
    chunkDurationSeconds: Double = 60.0,
    pollIntervalSeconds: Double = 2.0,
    vocabulary: Vocabulary = .empty
) {
    self.client = client
    self.diarize = diarize
    self.chunkDurationSeconds = chunkDurationSeconds
    self.pollIntervalSeconds = pollIntervalSeconds
    self.vocabulary = vocabulary
    let (stream, cont) = AsyncStream<TranscriptUpdate>.makeStream()
    self.updates = stream
    self.updatesContinuation = cont
}
```

- [ ] **Step 2: Rewrite per-chunk text before `assembler.add`.**

Modify `processChunk` — replace the `ChunkResult` construction with:

```swift
let cleanedText = VocabularyReplacer.apply(result.text, using: vocabulary)
let cr = ChunkResult(
    startMs: chunk.startMs,
    endMs: chunk.endMs,
    text: cleanedText,
    words: result.words,
    speakers: result.speakers,
    processingMs: result.processingMs
)
```

- [ ] **Step 3: Final belt-and-braces pass at finalize.**

Modify `finalize(startedAt:endedAt:)` — wrap the return:

```swift
let assembled = assembler.finalize(
    startedAt: startedAt,
    endedAt: endedAt,
    audioPath: audioURL?.path ?? ""
)
// Second pass — catches rules that spanned chunk boundaries.
var rewritten = assembled
rewritten.joinedText = VocabularyReplacer.apply(assembled.joinedText, using: vocabulary)
return rewritten
```

Import `HarcCore` in the file header if not already present.

- [ ] **Step 4: Integration test.**

Append to `Tests/HarcClientTests/ChunkedTranscriberTests.swift`:

```swift
    @Test("ChunkedTranscriber applies vocabulary to chunks and joinedText")
    func vocabularyIsApplied() async throws {
        // Use the existing stub-client test harness. Adapt to the actual name
        // used in this repo; if the harness is called `StubTranscribingClient`,
        // set it to return text containing "Arakeet".
        let stub = StubTranscribingClient(text: "Arakeet is fine")
        let vocab = Vocabulary(entries: [VocabularyEntry(from: "Arakeet", to: "Parakeet")])
        let t = ChunkedTranscriber(client: stub, chunkDurationSeconds: 1.0, vocabulary: vocab)
        // Drive a single-chunk WAV through via the existing fixture/helper.
        // ...existing test harness...
        let final = try await t.finalize(startedAt: Date(), endedAt: Date())
        #expect(final.joinedText.contains("Parakeet"))
        #expect(!final.joinedText.contains("Arakeet"))
    }
```

(If `ChunkedTranscriberTests` doesn't exist yet, create it with whatever minimal harness `TranscribingClient` needs — a tiny `StubTranscribingClient` returning canned `TranscribeResult`s on each `transcribe(…)` call is enough.)

- [ ] **Step 5: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
```

Expected: all tests green, strict-concurrency clean.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcClient/ChunkedTranscriber.swift Tests/HarcClientTests/
git commit -m "feat: ChunkedTranscriber applies vocabulary per chunk + at finalize"
```

---

### Task 4: Thread vocabulary through `AppDelegate` / `RecordingSession`

**Effort:** S

**Depends on:** Task 3

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/HarcApp/AppDelegate.swift`

- [ ] **Step 1: Pass `prefs.vocabulary` to `ChunkedTranscriber`.**

In `AppDelegate.startRecording`, update the `ChunkedTranscriber` construction:

```swift
let transcriber = ChunkedTranscriber(
    client: client,
    diarize: prefs.diarize,
    chunkDurationSeconds: prefs.chunkDurationSeconds,
    vocabulary: prefs.vocabulary
)
```

(The snapshot is taken at start time; edits during recording do not affect the live session, matching `diarize`/`chunkDurationSeconds` behavior.)

- [ ] **Step 2: Build + manual check**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED. No tests touched; next task adds the UI that exercises this.

- [ ] **Step 3: Commit**

```bash
git add HarcApp/AppDelegate.swift
git commit -m "feat: thread HarcPreferences.vocabulary into ChunkedTranscriber"
```

---

### Task 5: `ProcessingSettingsView` — the Vocabulary editor

**Effort:** M

**Depends on:** Task 0 (tabs scaffold), Task 1 (HarcPreferences methods)

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/Settings/ProcessingSettingsView.swift`

- [ ] **Step 1: Replace the stub body with the editor.**

Use the UI sketch in the design doc §7 verbatim. Key behaviors:
- `Table` of entries with checkbox / Heard / Replace-with columns, bound to `prefs.vocabulary.entries`.
- Add-row at the bottom with two `TextField`s and a disabled-when-empty Add button; trims whitespace before calling `prefs.addEntry`.
- Multi-select + delete (appears only when `selection` is non-empty).
- Footer text: "Drag rows to reorder — rules apply top to bottom. Applies to new recordings only."
- Header: "Vocabulary" with a short description paragraph.
- All text colors via `Color.harcOnSurface` / `Color.harcOnSurfaceVariant`.
- All fonts via `HarcDesign.Font.*`.
- All spacing via `HarcDesign.Space.*`.

Reorder-via-drag on `Table` requires iOS-18+/macOS-15+ APIs; in macOS 14 the fallback is a pair of up/down arrow buttons in a trailing column OR a `List { ForEach { … }.onMove(perform:) }` layout. Prefer the `List + ForEach.onMove` for macOS 14 compatibility:

```swift
List(selection: $selection) {
    ForEach(prefs.vocabulary.entries) { entry in
        VocabularyRow(entry: entry)
    }
    .onMove { src, dst in prefs.moveEntries(fromOffsets: src, toOffset: dst) }
    .onDelete { idx in
        let ids = idx.map { prefs.vocabulary.entries[$0].id }
        prefs.deleteEntries(ids: Set(ids))
    }
}
```

`VocabularyRow` is a private sub-view with the three columns laid out in an `HStack`.

- [ ] **Step 2: Move the Diarization toggle into this tab.**

From the existing `SettingsView` / `RecordingSettingsView`, lift the "Transcribe speakers (diarization)" Section into `ProcessingSettingsView` as a sibling Section above Vocabulary. Justification: diarization is a processing decision, not a recording device decision.

- [ ] **Step 3: Verify — build + run the app.**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Manual QA:
1. Open Settings → Processing.
2. Add `Arakeet → Parakeet`. Verify it appears in the list.
3. Disable via checkbox, re-enable.
4. Drag to reorder two entries.
5. Select + delete.
6. Relaunch the app — entries persist.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcUI/Settings/ProcessingSettingsView.swift Sources/HarcUI/Settings/RecordingSettingsView.swift
git commit -m "feat: Processing settings tab — Vocabulary editor + diarization toggle"
```

---

### Task 6: End-to-end smoke test + acceptance

**Effort:** S

**Depends on:** Tasks 0–5

**Files:** none (manual QA + final sweep)

- [ ] **Step 1: Record with a live rule.**

1. Add `Arakeet → Parakeet` in Processing.
2. Record a ~10-second clip that includes the word "Arakeet" (or a similar known-bad token).
3. Stop. Confirm:
   - Popover preview shows "Parakeet".
   - Pasteboard contains "Parakeet".
   - `.txt` sibling on disk contains "Parakeet".
   - `.json` sibling `joinedText` and each `chunks[*].text` contain "Parakeet".
   - SQLite `recordings.transcript_text` (open `Harc.db`) contains "Parakeet".
   - Existing pre-change recordings in the library are untouched.

- [ ] **Step 2: Mid-recording edit check.**

1. Start a recording.
2. Edit the vocabulary mid-way (add a new rule).
3. Stop. Confirm the new rule did NOT apply to this session — previous-session snapshot wins.
4. Start a new recording with the same content — confirm the new rule DOES apply.

- [ ] **Step 3: Full test sweep.**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test 2>&1 | tail -10
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: all tests green (count = prior + 14 VocabularyReplacer tests + 2 HarcPreferences tests + 1 ChunkedTranscriber test). Strict-concurrency clean. xcodebuild green.

- [ ] **Step 4: Final commit**

No code changes — just a marker commit if desired, or skip.

---

## Task Dependency Graph

```
  Task 0 (tabs scaffold) ──┐
                           ├──► Task 5 (UI)
  Task 1 (model + prefs) ──┤
        │                  │
        ▼                  │
  Task 2 (replacer) ──► Task 3 (ChunkedTranscriber) ──► Task 4 (AppDelegate) ──► Task 6 (QA)
                                                                                      ▲
  Task 5 (UI) ─────────────────────────────────────────────────────────────────────────┘
```

- **Parallelizable:** Task 0 and Task 1 can run in parallel — no shared files.
- **Sequential:** Task 2 → 3 → 4 (build-up of the pipeline wiring).
- **Final integration:** Task 5 unblocks the QA in Task 6; Task 4 must also be done before Task 6.

## Effort Summary

| Task | Effort | Blocking? |
|---|---|---|
| 0: Tabs scaffold | M | Blocks Task 5 |
| 1: Model + prefs | S | Blocks Tasks 2, 5 |
| 2: Replacer core | M | Blocks Task 3 |
| 3: Wire to ChunkedTranscriber | S | Blocks Task 4 |
| 4: AppDelegate thread-through | S | Blocks Task 6 |
| 5: UI | M | Blocks Task 6 |
| 6: E2E + acceptance | S | — |

Total rough effort: ~1.5 dev-days solo.

## Acceptance Criteria

- `VocabularyReplacer.apply` passes all 14+ unit tests (case, word-boundary, multi-word, idempotent, regex-safe, unicode, disabled-skip).
- `HarcPreferences.vocabulary` round-trips through `UserDefaults`.
- New recordings show corrected text in popover preview, pasteboard, `.txt`, `.json` (joinedText + chunks[].text), and SQLite `transcript_text`.
- Existing recordings are NOT rewritten.
- Editing vocabulary mid-recording doesn't affect the in-flight session.
- Settings → Processing tab renders the Vocabulary editor with add / edit / delete / toggle / reorder.
- `swift test` green, strict-concurrency clean, xcodebuild green.

## Out of Scope (v1)

- Retroactive rewriting of existing library.
- Regex / phonetic / fuzzy matching.
- Per-project vocabularies.
- Import/export.
- Word-timing patch-up after multi-word collapse.
- Live preview / "Try it" sandbox in the Processing tab.
