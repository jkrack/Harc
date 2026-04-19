# Copy for Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the default clipboard payload from bare transcript text to a prompt-formatted Markdown blob with YAML front-matter, and add a matching `Export for Prompt…` file format. Existing raw-text behavior remains reachable via a secondary "Copy Plain Text" action.

**Design doc:** `/Users/jlane/GitHub/Harc/docs/superpowers/specs/2026-04-19-copy-for-prompt-design.md`

**Architecture:** All logic lives in `HarcExport`. A new internal `PromptFrontMatter` renderer turns `ExportInput` into a YAML block; a new public `ExportService.promptString(for:)` composes `PromptFrontMatter.render + MarkdownExporter.render`. `ExportFormat` gains a `.prompt` case that writes to `<stem>.prompt.md`. HarcUI swaps two call sites (`LibraryWindowRootView` detail pane, `TranscriptionDetailView` toolbar) to the new clipboard content and adds the `Export for Prompt…` menu item.

**Tech stack:** Swift 6, Swift Testing, AppKit (`NSPasteboard`, `NSSavePanel`), no new third-party deps.

---

## Dependency graph

```
Task 1 (ExportInput.tags)
  └─▶ Task 2 (ExportInputBuilder populates tags)
           │
Task 3 (PromptFrontMatter.formatDuration)
Task 4 (PromptFrontMatter.formatRecorded)
Task 5 (PromptFrontMatter.yamlScalar)
Task 6 (PromptFrontMatter.speakerCount)
           │
           └─▶ Task 7 (PromptFrontMatter.render — composes helpers + tags)
                    └─▶ Task 8 (ExportService.promptString)
                             └─▶ Task 9 (ExportFormat.prompt case)
                                      └─▶ Task 10 (write + defaultDestination for .prompt)
                                               └─▶ Task 11 (LibraryWindowRootView UI)
                                               └─▶ Task 12 (TranscriptionDetailView UI)
                                                        └─▶ Task 13 (manual verification)
```

Tasks 3–6 are independent and may be implemented in any order (or parallelised).

---

## Effort summary

| Task | Effort | Gates |
|------|--------|-------|
| 1. Extend `ExportInput` with `tags` | S | `swift test --filter ExportInput` |
| 2. `ExportInputBuilder` populates tags | S | `swift test --filter ExportInputBuilder` |
| 3. `PromptFrontMatter.formatDuration` | S | `swift test --filter PromptFrontMatter` |
| 4. `PromptFrontMatter.formatRecorded` | S | `swift test --filter PromptFrontMatter` |
| 5. `PromptFrontMatter.yamlScalar` | S | `swift test --filter PromptFrontMatter` |
| 6. `PromptFrontMatter.speakerCount` | S | `swift test --filter PromptFrontMatter` |
| 7. `PromptFrontMatter.render` integration | M | `swift test --filter PromptFrontMatter` |
| 8. `ExportService.promptString` | S | `swift test --filter ExportService` |
| 9. `ExportFormat.prompt` case | S | `swift build` |
| 10. `write` + `defaultDestination` for `.prompt` | S | `swift test --filter ExportService` |
| 11. Library UI — Copy for Prompt + Export menu | M | xcodebuild + manual click-through |
| 12. Detail view UI — Copy for Prompt + Paste swap | S | xcodebuild + manual |
| 13. Manual verification | S | full `swift test`, smoke checklist |

---

### Task 1: Extend `ExportInput` with `tags`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInput.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputTests.swift` inside the existing `@Suite("ExportInput") struct ExportInputTests`:

```swift
    @Test("tags defaults to empty when omitted")
    func tagsDefaultsEmpty() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: []
        )
        #expect(input.tags.isEmpty)
    }

    @Test("tags round-trip via initializer")
    func tagsRoundTrip() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            tags: ["Harc", "standup"],
            segments: []
        )
        #expect(input.tags == ["Harc", "standup"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExportInputTests`
Expected: compile error — `ExportInput` initializer has no `tags:` parameter and no `tags` property.

- [ ] **Step 3: Add `tags` to `ExportInput`**

Replace the body of `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInput.swift` with:

```swift
import Foundation

/// Neutral input shape consumed by every exporter. Renderers are pure
/// functions over this type — no filesystem, no AppKit, no GRDB.
public struct ExportInput: Equatable, Sendable {
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int?
    public let tags: [String]
    public let segments: [Segment]

    public init(
        title: String,
        startedAt: Date,
        durationSeconds: Int?,
        tags: [String] = [],
        segments: [Segment]
    ) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.segments = segments
    }

    public struct Segment: Equatable, Sendable {
        /// 0-based speaker id from diarization. `nil` means "no speaker
        /// attribution" (single-speaker or diarization-off). Renderers map
        /// to 1-based labels ("Speaker 1").
        public let speaker: Int?
        /// Already trimmed, non-empty, \r stripped.
        public let text: String

        public init(speaker: Int?, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    /// True if any segment has a non-nil speaker id.
    public var isDiarized: Bool {
        segments.contains { $0.speaker != nil }
    }
}
```

`tags` defaults to `[]` so existing `ExportInput(...)` call sites keep compiling.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ExportInputTests`
Expected: all `ExportInputTests` pass.

- [ ] **Step 5: Run the full test suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HarcExport/ExportInput.swift Tests/HarcExportTests/ExportInputTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportInput gains tags: [String]

Optional, defaults to []. Consumed by PromptFrontMatter (next).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `ExportInputBuilder` populates `tags`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInputBuilder.swift`
- Test: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputBuilderTests.swift`:

```swift
    @Test("tags flow from Recording.tags into ExportInput")
    func tagsFlow() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi",
            tags: ["Acme", "Q3"]
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.tags == ["Acme", "Q3"])
    }

    @Test("tags default to empty when Recording has none")
    func tagsEmptyByDefault() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            startedAt: Date(),
            transcriptText: "hi"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.tags.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExportInputBuilderTests`
Expected: the two new tests fail — `input.tags` is always empty because `ExportInputBuilder` does not yet thread tags.

- [ ] **Step 3: Thread `tags` through `ExportInputBuilder.build(from:)`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInputBuilder.swift`, update all three `ExportInput(...)` construction sites to pass `tags: recording.tags`. The three sites are the JSON-present branch, the `transcriptText` fallback branch, and the empty branch at the bottom.

Full replacement for the `build(from:)` function:

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
                segments: [.init(speaker: nil, text: text)]
            )
        }

        return ExportInput(
            title: title,
            startedAt: recording.startedAt,
            durationSeconds: duration,
            tags: recording.tags,
            segments: []
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ExportInputBuilderTests`
Expected: all `ExportInputBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/ExportInputBuilder.swift Tests/HarcExportTests/ExportInputBuilderTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportInputBuilder threads Recording.tags

Prompt front-matter will read tags from ExportInput.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `PromptFrontMatter.formatDuration`

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`:

```swift
import Testing
import Foundation
@testable import HarcExport

@Suite("PromptFrontMatter")
struct PromptFrontMatterTests {

    // MARK: formatDuration

    @Test("formatDuration — 0 seconds", arguments: [
        (0, "0s"),
        (1, "1s"),
        (59, "59s"),
        (60, "1m"),
        (119, "1m"),        // truncated (not rounded to 2m)
        (3599, "59m"),
        (3600, "1h 0m"),
        (5400, "1h 30m"),
        (86400, "24h 0m"),
    ])
    func formatDuration(input: Int, expected: String) {
        #expect(PromptFrontMatter.formatDuration(input) == expected)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PromptFrontMatterTests`
Expected: compile error — `PromptFrontMatter` type does not exist.

- [ ] **Step 3: Create `PromptFrontMatter.swift` with `formatDuration`**

Create `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`:

```swift
import Foundation

/// Renders the YAML front-matter block that prefixes the prompt-formatted
/// export. Internal to `HarcExport`; consumed by `ExportService.promptString`.
enum PromptFrontMatter {

    /// Format a non-negative duration as the compact shape used in the YAML
    /// `duration:` field: `<N>s` for < 60s, `<N>m` for < 1h, `<H>h <M>m`
    /// at 1h+. Minutes and hours truncate — `119s → "1m"`, not `"2m"`.
    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all `formatDuration` cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter.formatDuration

Compact duration format for YAML front-matter. Table-driven tests cover
the <60s, <1h, and 1h+ branches including truncation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `PromptFrontMatter.formatRecorded`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `PromptFrontMatterTests`:

```swift
    // MARK: formatRecorded

    @Test("formatRecorded — ISO 8601 with supplied timezone")
    func formatRecordedLA() {
        // 2026-04-19 14:32:00 America/Los_Angeles = 2026-04-19T21:32:00Z
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 14; comps.minute = 32; comps.second = 0
        comps.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        #expect(PromptFrontMatter.formatRecorded(date, timeZone: tz) == "2026-04-19T14:32:00-07:00")
    }

    @Test("formatRecorded — UTC renders +00:00")
    func formatRecordedUTC() {
        let tz = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        #expect(PromptFrontMatter.formatRecorded(date, timeZone: tz) == "2023-11-14T22:13:20+00:00")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptFrontMatterTests`
Expected: compile error — `formatRecorded` does not exist.

- [ ] **Step 3: Add `formatRecorded` to `PromptFrontMatter`**

Append inside the `PromptFrontMatter` enum in `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`:

```swift
    /// ISO 8601 with an explicit offset — e.g. `2026-04-19T14:32:00-07:00`.
    /// The `timeZone` parameter exists for deterministic tests; production
    /// callers pass `.current`.
    static func formatRecorded(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: date)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all `formatRecorded` cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter.formatRecorded (ISO 8601 with offset)

en_US_POSIX locale for determinism, timezone param for test control.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `PromptFrontMatter.yamlScalar`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `PromptFrontMatterTests`:

```swift
    // MARK: yamlScalar

    @Test("yamlScalar — plain string passes through unquoted")
    func yamlScalarPlain() {
        #expect(PromptFrontMatter.yamlScalar("Standup with Jason") == "Standup with Jason")
        #expect(PromptFrontMatter.yamlScalar("Harc, standup") == "Harc, standup")
    }

    @Test("yamlScalar — values with : get quoted")
    func yamlScalarColon() {
        // A colon followed by space requires quoting per YAML 1.2.
        #expect(PromptFrontMatter.yamlScalar("foo: bar") == "\"foo: bar\"")
    }

    @Test("yamlScalar — leading-indicator characters get quoted")
    func yamlScalarIndicator() {
        #expect(PromptFrontMatter.yamlScalar("- dash lead") == "\"- dash lead\"")
        #expect(PromptFrontMatter.yamlScalar("# hash lead") == "\"# hash lead\"")
        #expect(PromptFrontMatter.yamlScalar("@at lead") == "\"@at lead\"")
    }

    @Test("yamlScalar — double-quoted escapes handle quotes and backslash")
    func yamlScalarEscapes() {
        #expect(PromptFrontMatter.yamlScalar(#"he said "hi""#) == #""he said \"hi\"""#)
        #expect(PromptFrontMatter.yamlScalar(#"path\to"#) == #""path\\to""#)
    }

    @Test("yamlScalar — whitespace-only/leading-or-trailing-space gets quoted")
    func yamlScalarWhitespace() {
        #expect(PromptFrontMatter.yamlScalar(" leading") == "\" leading\"")
        #expect(PromptFrontMatter.yamlScalar("trailing ") == "\"trailing \"")
        #expect(PromptFrontMatter.yamlScalar("") == "\"\"")
    }

    @Test("yamlScalar — newlines and tabs get escaped")
    func yamlScalarControlChars() {
        #expect(PromptFrontMatter.yamlScalar("a\nb") == "\"a\\nb\"")
        #expect(PromptFrontMatter.yamlScalar("a\tb") == "\"a\\tb\"")
    }

    @Test("yamlScalar — control chars below 0x20 are stripped before decision")
    func yamlScalarControlStripped() {
        // \u{0001} (SOH) gets stripped → just "ab", passes through plain.
        #expect(PromptFrontMatter.yamlScalar("a\u{0001}b") == "ab")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptFrontMatterTests`
Expected: compile error — `yamlScalar` does not exist.

- [ ] **Step 3: Add `yamlScalar` to `PromptFrontMatter`**

Append inside the `PromptFrontMatter` enum in `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`:

```swift
    /// Render a string as a YAML scalar. Returns the input unchanged if the
    /// value is safe as a plain (unquoted) scalar; otherwise returns a
    /// double-quoted scalar with escapes. Strips control chars below 0x20
    /// except for `\n` and `\t` (which are escaped), matching
    /// `MarkdownExporter.sanitize()`'s policy.
    static func yamlScalar(_ value: String) -> String {
        // Strip disallowed control chars first (same policy as
        // MarkdownExporter, except we handle \n/\t via escapes instead
        // of passing them through).
        let filtered = String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }   // \t, \n — escaped below
            if v < 0x20 { return false }                // drop other control chars
            return true
        }))

        if mustQuote(filtered) {
            return "\"\(doubleQuoteEscape(filtered))\""
        }
        return filtered
    }

    private static let reservedLeadingChars: Set<Character> = [
        "!", "&", "*", "-", ":", "?", "{", "}", "[", "]", ",",
        "#", "|", ">", "'", "\"", "%", "@", "`",
    ]

    private static func mustQuote(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if let first = s.first, reservedLeadingChars.contains(first) { return true }
        if let first = s.first, first.isWhitespace { return true }
        if let last = s.last, last.isWhitespace { return true }
        if s.contains("\n") || s.contains("\r") || s.contains("\t") { return true }
        if s.contains(": ") || s.hasSuffix(":") { return true }
        return false
    }

    private static func doubleQuoteEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all `yamlScalar` tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter.yamlScalar (plain vs double-quoted)

YAML 1.2-ish plain-scalar detection with conservative double-quote
fallback. Control chars below 0x20 are stripped; \\n/\\t are escaped.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `PromptFrontMatter.speakerCount`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `PromptFrontMatterTests`:

```swift
    // MARK: speakerCount

    @Test("speakerCount — empty segments → 0")
    func speakerCountEmpty() {
        #expect(PromptFrontMatter.speakerCount(in: []) == 0)
    }

    @Test("speakerCount — nil-speaker segments don't count")
    func speakerCountNilOnly() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: nil, text: "a"),
            .init(speaker: nil, text: "b"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 0)
    }

    @Test("speakerCount — distinct speaker ids are counted once each")
    func speakerCountDistinct() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: 0, text: "a"),
            .init(speaker: 1, text: "b"),
            .init(speaker: 0, text: "c"),      // duplicate id
            .init(speaker: 2, text: "d"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 3)
    }

    @Test("speakerCount — mixed nil and ids")
    func speakerCountMixed() {
        let segs: [ExportInput.Segment] = [
            .init(speaker: nil, text: "a"),
            .init(speaker: 0, text: "b"),
        ]
        #expect(PromptFrontMatter.speakerCount(in: segs) == 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptFrontMatterTests`
Expected: compile error — `speakerCount` does not exist.

- [ ] **Step 3: Add `speakerCount` to `PromptFrontMatter`**

Append inside the `PromptFrontMatter` enum:

```swift
    /// Count of distinct non-nil speaker ids in `segments`. Returns 0 for
    /// un-diarized input. Used to decide whether the `speakers:` field is
    /// emitted (only when >= 2).
    static func speakerCount(in segments: [ExportInput.Segment]) -> Int {
        var seen: Set<Int> = []
        for s in segments {
            if let id = s.speaker { seen.insert(id) }
        }
        return seen.count
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all `speakerCount` tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter.speakerCount

Counts distinct non-nil speaker ids for the speakers: front-matter field.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `PromptFrontMatter.render` (integration)

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/PromptFrontMatter.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/PromptFrontMatterTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `PromptFrontMatterTests`:

```swift
    // MARK: render

    private func laTZ() -> TimeZone { TimeZone(identifier: "America/Los_Angeles")! }

    private func fixedDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 14; comps.minute = 32; comps.second = 0
        comps.timeZone = laTZ()
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    @Test("render — full set of fields in fixed order")
    func renderFull() {
        let input = ExportInput(
            title: "Standup with Jason",
            startedAt: fixedDate(),
            durationSeconds: 2820, // 47m
            tags: ["standup", "Jason", "Harc"],
            segments: [
                .init(speaker: 0, text: "Hi"),
                .init(speaker: 1, text: "Hey"),
            ]
        )
        let expected = """
        ---
        title: Standup with Jason
        recorded: 2026-04-19T14:32:00-07:00
        duration: 47m
        tags: standup, Jason, Harc
        speakers: 2
        ---
        """
        #expect(PromptFrontMatter.render(input, timeZone: laTZ()) == expected)
    }

    @Test("render — omits empty title")
    func renderOmitsEmptyTitle() {
        let input = ExportInput(
            title: "",
            startedAt: fixedDate(),
            durationSeconds: 30,
            segments: [.init(speaker: nil, text: "x")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("title:"))
        #expect(out.contains("recorded: 2026-04-19T14:32:00-07:00"))
        #expect(out.contains("duration: 30s"))
    }

    @Test("render — omits duration when nil")
    func renderOmitsDuration() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: nil,
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("duration:"))
    }

    @Test("render — omits tags when empty")
    func renderOmitsTags() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            tags: [],
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("tags:"))
    }

    @Test("render — omits speakers when count < 2")
    func renderOmitsSpeakersSingle() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            segments: [.init(speaker: 0, text: "alone")]
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(!out.contains("speakers:"))
    }

    @Test("render — tags with a colon force the whole tags line to be quoted")
    func renderQuotesTagsWithColon() {
        let input = ExportInput(
            title: "t",
            startedAt: fixedDate(),
            durationSeconds: 30,
            tags: ["foo: bar", "baz"],
            segments: []
        )
        let out = PromptFrontMatter.render(input, timeZone: laTZ())
        #expect(out.contains("tags: \"foo: bar, baz\""))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PromptFrontMatterTests`
Expected: compile error — `render` does not exist.

- [ ] **Step 3: Add `render` to `PromptFrontMatter`**

Append inside the `PromptFrontMatter` enum:

```swift
    /// Render the full YAML front-matter block, including opening and closing
    /// `---` delimiters. Does NOT add a trailing blank line — the composer in
    /// `ExportService.promptString` owns spacing between header and body.
    static func render(_ input: ExportInput, timeZone: TimeZone = .current) -> String {
        var lines: [String] = ["---"]

        let trimmedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            lines.append("title: \(yamlScalar(trimmedTitle))")
        }

        lines.append("recorded: \(formatRecorded(input.startedAt, timeZone: timeZone))")

        if let secs = input.durationSeconds {
            lines.append("duration: \(formatDuration(secs))")
        }

        if !input.tags.isEmpty {
            let joined = input.tags.joined(separator: ", ")
            lines.append("tags: \(yamlScalar(joined))")
        }

        let speakers = speakerCount(in: input.segments)
        if speakers >= 2 {
            lines.append("speakers: \(speakers)")
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PromptFrontMatterTests`
Expected: all `PromptFrontMatter` tests (including the new `render` ones) pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/PromptFrontMatter.swift Tests/HarcExportTests/PromptFrontMatterTests.swift
git commit -m "$(cat <<'EOF'
feat(export): PromptFrontMatter.render composes the YAML block

Stable field order: title / recorded / duration / tags / speakers.
Empty/nil fields are omitted; speakers emitted only when count >= 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `ExportService.promptString(for:)`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the existing `@Suite("ExportService") struct ExportServiceTests`:

```swift
    @Test("promptString = PromptFrontMatter.render + blank line + MarkdownExporter.render")
    func promptStringComposesHeaderAndBody() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "hello body",
            tags: ["Acme"]
        )
        let input = ExportInputBuilder.build(from: rec)
        let expectedHeader = PromptFrontMatter.render(input)
        let expectedBody = MarkdownExporter.render(input)
        let prompt = ExportService.promptString(for: rec)
        #expect(prompt == expectedHeader + "\n\n" + expectedBody)
    }

    @Test("promptString — empty body yields header + single trailing newline")
    func promptStringEmptyBody() {
        let rec = Recording(wavPath: "/tmp/x.wav", startedAt: Date())
        let prompt = ExportService.promptString(for: rec)
        let input = ExportInputBuilder.build(from: rec)
        let header = PromptFrontMatter.render(input)
        #expect(prompt == header + "\n")
        #expect(!prompt.contains("\n\n"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExportServiceTests`
Expected: compile error — `ExportService.promptString(for:)` does not exist.

- [ ] **Step 3: Add `promptString(for:)` to `ExportService`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`, below the existing `markdownString(for:)` method, add:

```swift
    /// Render the prompt-formatted blob — YAML front-matter + Markdown body —
    /// for clipboard or `.prompt.md` export. Pure.
    public static func promptString(for recording: Recording) -> String {
        let input = ExportInputBuilder.build(from: recording)
        let header = PromptFrontMatter.render(input)
        let body = MarkdownExporter.render(input)
        if body.isEmpty { return header + "\n" }
        return header + "\n\n" + body
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ExportServiceTests`
Expected: all `ExportServiceTests` (including the two new `promptString` tests) pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/ExportService.swift Tests/HarcExportTests/ExportServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportService.promptString composes header + markdown body

Pure function, single trailing newline when body is empty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `ExportFormat.prompt` case

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`

- [ ] **Step 1: Extend `ExportFormat`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`, replace the `ExportFormat` enum (top of file) with:

```swift
public enum ExportFormat: Sendable {
    case markdown
    case docx
    case prompt

    public var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .docx:     return "docx"
        case .prompt:   return "md"
        }
    }
}
```

- [ ] **Step 2: Verify the switch in `write(recording:format:to:)` still compiles**

At this point `ExportService.write(...)`'s `switch format` does not yet handle `.prompt`. Swift 6 enforces exhaustive switches, so the build will fail until Task 10.

Run: `swift build`
Expected: build error — "switch must be exhaustive ... missing case .prompt".

This is the expected failure that Task 10 will fix. Do **not** commit yet — Task 10 completes the `.prompt` case wiring and commits both changes together.

---

### Task 10: `write` + `defaultDestination` support `.prompt`

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`
- Modify: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `ExportServiceTests`:

```swift
    @Test("defaultDestination for .prompt uses <stem>.prompt.md in the recording folder")
    func defaultDestinationPrompt() {
        let rec = Recording(
            wavPath: "/tmp/harc/2026/2026-04-19/10-00-00.wav",
            startedAt: Date()
        )
        let url = ExportService.defaultDestination(for: rec, format: .prompt)
        #expect(url.path == "/tmp/harc/2026/2026-04-19/10-00-00.prompt.md")
    }

    @Test("write .prompt writes the promptString bytes atomically")
    func writesPrompt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: Date(),
            transcriptText: "hello prompt",
            tags: ["demo"]
        )
        let target = tmp.appendingPathComponent("x.prompt.md")
        try ExportService.write(recording: rec, format: .prompt, to: target)
        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(contents == ExportService.promptString(for: rec))
        #expect(contents.hasPrefix("---\n"))
        #expect(contents.contains("tags: demo"))
        #expect(contents.contains("hello prompt"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build`
Expected: the pre-existing exhaustive-switch error from Task 9 still bites. That is the TDD failure — the switch can't compile until `.prompt` is handled.

- [ ] **Step 3: Extend `write(recording:format:to:)` and `defaultDestination`**

In `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`:

**(a)** Replace the `switch format { ... }` in `write(recording:format:to:)` with:

```swift
        switch format {
        case .markdown:
            data = Data(MarkdownExporter.render(input).utf8)
        case .docx:
            data = try DocxExporter.render(input)
        case .prompt:
            data = Data(ExportService.promptString(for: recording).utf8)
        }
```

Note: the `.prompt` branch goes through `promptString(for: recording)` rather than re-using the `input` local — this keeps the composition identical to the clipboard path and ensures `promptString`'s empty-body handling applies.

**(b)** Replace `defaultDestination(for:format:)` with:

```swift
    public static func defaultDestination(for recording: Recording, format: ExportFormat) -> URL {
        let wav = URL(fileURLWithPath: recording.wavPath)
        let stem = wav.deletingPathExtension().lastPathComponent
        let folder = wav.deletingLastPathComponent()
        switch format {
        case .markdown, .docx:
            return folder.appendingPathComponent("\(stem).\(format.filenameExtension)")
        case .prompt:
            return folder.appendingPathComponent("\(stem).prompt.md")
        }
    }
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all tests pass, including the two new `ExportServiceTests` and everything previously green.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcExport/ExportService.swift Tests/HarcExportTests/ExportServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(export): ExportFormat.prompt writes <stem>.prompt.md

write() routes .prompt through promptString; defaultDestination appends
.prompt.md to avoid clobbering a plain Markdown export in the same folder.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Library UI — Copy for Prompt + Export menu

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift:325-396`

- [ ] **Step 1: Replace `exportControls(for:)` and the copy helpers**

In `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift`, locate the `exportControls(for:)` function (around line 325) and replace it and the `copyMarkdown(_:)` helper with the following block:

```swift
    private func exportControls(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("EXPORT")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .tracking(1.2)
            HStack(spacing: HarcDesign.Space.sm) {
                Menu {
                    Button("Export Markdown…")    { runExport(rec, format: .markdown) }
                    Button("Export DOCX…")        { runExport(rec, format: .docx) }
                    Button("Export for Prompt…")  { runExport(rec, format: .prompt) }
                    Divider()
                    Button("Copy for Prompt")     { copyPromptString(rec) }
                    Button("Copy Plain Text")     { copyPlainText(rec) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    copyPromptString(rec)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Copy for Prompt")
                    }
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcPrimary)
                }
                .buttonStyle(.plain)
            }
            if let msg = exportErrorMessage {
                Text(msg)
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcError)
            }
        }
    }

    private func copyPromptString(_ rec: Recording) {
        let s = ExportService.promptString(for: rec)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        exportErrorMessage = nil
    }

    private func copyPlainText(_ rec: Recording) {
        let input = ExportInputBuilder.build(from: rec)
        let text = input.segments.map { $0.text }.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        exportErrorMessage = nil
    }
```

This replaces the old `copyMarkdown(_:)` helper entirely. `runExport(_:format:)` above it is unchanged.

- [ ] **Step 2: Confirm `ExportInputBuilder` is importable here**

`LibraryWindowRootView.swift` already has `import HarcExport` at the top. `ExportInputBuilder` is a public enum in that module and is visible. If a build error about `ExportInputBuilder` being inaccessible shows up, that's a signal it was implicitly-internal — verify it is declared `public enum ExportInputBuilder` (it is).

- [ ] **Step 3: Build the package**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Build the Xcode project to catch AppKit/SwiftUI-specific issues**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds. If it fails with deprecation warnings only, the build is still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/LibraryWindowRootView.swift
git commit -m "$(cat <<'EOF'
feat(ui): Library — Copy for Prompt + Export for Prompt

Rename "Copy Markdown" button/menu item to "Copy for Prompt"; add
"Export for Prompt…" to the Export menu and "Copy Plain Text" as a
secondary clipboard action.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Transcription detail view — Copy for Prompt + Paste swap

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift:86-105`

- [ ] **Step 1: Confirm the import**

`TranscriptionDetailView.swift` already has `import HarcStore` and does not import `HarcExport`. Add the import near the top:

Locate the imports at the top of `/Users/jlane/GitHub/Harc/Sources/HarcUI/TranscriptionDetailView.swift`:

```swift
import SwiftUI
import AppKit
import HarcStore
```

Add `import HarcExport` directly below `import HarcStore`:

```swift
import SwiftUI
import AppKit
import HarcStore
import HarcExport
```

- [ ] **Step 2: Replace the `toolbar` HStack**

Locate the `toolbar` computed property. Replace the two leading buttons (the current `Copy` button and the `Paste` button) with the following. The `Reveal` and `Delete` buttons below are unchanged.

Find (around line 86):

```swift
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

            Button {
                try? FrontmostAppPaster.copyAndPaste(transcript)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("Copy to clipboard and paste into the frontmost app")
```

Replace with:

```swift
    private var toolbar: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Menu {
                Button("Copy for Prompt")  { copyPromptString() }
                Button("Copy Plain Text")  { copyPlainText() }
            } label: {
                Label("Copy for Prompt", systemImage: "doc.on.clipboard")
            }
            .menuStyle(.borderlessButton)
            .disabled(transcript.isEmpty)
            .help("Copy the prompt-formatted blob (default) or plain text")

            Button {
                let s = ExportService.promptString(for: recording)
                try? FrontmostAppPaster.copyAndPaste(s)
            } label: {
                Label("Paste", systemImage: "text.viewfinder")
            }
            .disabled(transcript.isEmpty)
            .help("Copy the prompt blob to clipboard and paste into the frontmost app")
```

- [ ] **Step 3: Add the two helper methods**

Anywhere inside `TranscriptionDetailView` (below `toolbar` is fine), add:

```swift
    private func copyPromptString() {
        let s = ExportService.promptString(for: recording)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func copyPlainText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
    }
```

`transcript` is the `@State` string already loaded by `load()`; reuse keeps behavior identical to the old Copy button.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: build succeeds.

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcUI/TranscriptionDetailView.swift
git commit -m "$(cat <<'EOF'
feat(ui): TranscriptionDetailView — Copy for Prompt + Paste uses prompt blob

Copy becomes a split menu (prompt default / plain text secondary). Paste
button's clipboard transit now carries the prompt-formatted blob, matching
the Library Copy-for-Prompt behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: End-to-end manual verification

**Files:** none (smoke pass)

- [ ] **Step 1: Full test suite green**

Run: `swift test`
Expected: 0 failures across all targets.

- [ ] **Step 2: Build the app for manual testing**

Run: `xcodebuild -project Harc.xcodeproj -scheme Harc build -quiet`
Expected: build succeeds.

- [ ] **Step 3: Manual smoke — Library detail pane**

Launch Harc, open the Library window, pick a recent recording.

1. Click **Copy for Prompt**. Open a text editor, paste. Verify the pasted content starts with `---`, has `recorded: <iso>`, ends with `---`, a blank line, then the transcript body.
2. Click the **Export ▾** menu. Verify the items are in order: `Export Markdown…`, `Export DOCX…`, `Export for Prompt…`, divider, `Copy for Prompt`, `Copy Plain Text`.
3. Click **Export for Prompt…**. Accept the default filename. Verify the saved file is `<HH-mm-ss>.prompt.md` in the recording's folder and matches the earlier clipboard content exactly.
4. Click **Copy Plain Text**. Paste into a text editor. Verify there is no YAML block, no `Speaker N:` prefixes, just segment text joined by blank lines.

- [ ] **Step 4: Manual smoke — Transcription detail window**

Open the transcription detail window for a recording (from the Library double-click or menu-bar flow).

1. Click **Copy for Prompt** (the top-level button). Paste — verify prompt blob.
2. Click the disclosure/menu and pick **Copy Plain Text**. Paste — verify raw transcript (no YAML, no speaker prefixes if it's a plain-text recording; speaker prefixes preserved from the stored `.txt` if diarized).
3. Click **Paste**. Focus should return to the previously-frontmost app and the prompt blob should paste there.

- [ ] **Step 5: Manual smoke — edge cases**

1. Repeat the Copy-for-Prompt flow on a **single-speaker** recording. Verify the pasted blob's front-matter does NOT contain a `speakers:` line.
2. Repeat on a recording whose **title or tag contains `:`** (create one by editing the title to `Foo: Bar`). Verify the pasted blob has `title: "Foo: Bar"` (double-quoted) and parses cleanly in a YAML validator.
3. Repeat on a recording with **no tags**. Verify the pasted blob has no `tags:` line.

- [ ] **Step 6: Rebuild and sanity-check for warnings**

Run: `swift build 2>&1 | grep -E 'warning:' || true`
Expected: no new warnings introduced by this feature. Pre-existing warnings are fine.

- [ ] **Step 7: Final commit (docs) — optional**

If anything in the spec needs clarification based on what you found during manual verification, update `docs/superpowers/specs/2026-04-19-copy-for-prompt-design.md` and commit:

```bash
git add docs/superpowers/specs/2026-04-19-copy-for-prompt-design.md
git commit -m "$(cat <<'EOF'
docs(copy-for-prompt): clarifications from manual verification

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Otherwise skip.

---

## Self-review notes

- **Spec coverage:** every requirement in §4 of the spec is wired to a task: `ExportInput.tags` (T1), builder population (T2), `PromptFrontMatter` helpers (T3–T6) and composition (T7), `promptString` (T8), `ExportFormat.prompt` (T9), `write`/`defaultDestination` (T10), Library UI (T11), Detail UI (T12). §7 tests are mapped into T1/T2/T3–T7/T8/T10. §3 field rules and omissions are tested in T7. §3.3 YAML escaping is tested in T5 and exercised end-to-end in T7's colon-tag test.
- **Type consistency:** every helper name used in later tasks (`formatRecorded`, `formatDuration`, `yamlScalar`, `speakerCount`, `render`) is defined in the exact spelling used, and `PromptFrontMatter.render` takes a `timeZone:` parameter defaulting to `.current` — pinned across T4, T7, and their tests.
- **Commit cadence:** one commit per task; `ExportFormat.prompt` intentionally shares a commit with T10 because the enum's exhaustive-switch requirement means T9's isolated state cannot compile. This is called out explicitly in T9.
- **Manual-smoke scope:** limited to behaviors changed by this plan (clipboard content, new export format, renamed buttons). No mic capture or daemon work is exercised.
