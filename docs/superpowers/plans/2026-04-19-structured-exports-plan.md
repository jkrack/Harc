# Structured Exports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On-demand Markdown + DOCX export from the Library detail pane, with a Copy Markdown clipboard shortcut. Renderers are pure and unit-tested; a thin `ExportService` handles file I/O.

**Design doc:** `/Users/jlane/GitHub/Harc/docs/superpowers/specs/2026-04-19-structured-exports-design.md`

**Architecture:** New `HarcExport` SwiftPM target. Pure Swift renderers (`MarkdownExporter`, `DocxExporter`) operate on a neutral `ExportInput` value type. `ExportService` loads `SessionTranscript` JSON from disk (with `Recording.transcriptText` fallback), builds `ExportInput`, and either writes the rendered bytes to a URL or places the Markdown on the pasteboard. UI lives in `LibraryWindowRootView.detailContent` as a `Menu` with `Export ▾` + a `Copy Markdown` button, using `NSSavePanel` for destination.

**Tech stack:** Swift 6, AppKit (`NSAttributedString`, `NSSavePanel`, `NSPasteboard`), no new third-party deps.

---

## Dependency graph

```
Task 1 (HarcExport scaffold + ExportInput)
    └─▶ Task 2 (MarkdownExporter + tests)
    └─▶ Task 3 (DocxExporter + tests)
    └─▶ Task 4 (ExportInputBuilder: JSON → ExportInput)
             └─▶ Task 5 (ExportService: I/O façade)
                      └─▶ Task 6 (UI: Export menu + Save panel + Copy)
                               └─▶ Task 7 (End-to-end manual verification + commit-clean)
```

Tasks 2 and 3 can be parallelised once Task 1 lands. Task 4 can overlap with 2/3 because it only depends on Task 1's `ExportInput` type.

---

## Effort summary

| Task | Effort | Gates |
|---|---|---|
| 1. `HarcExport` scaffold + `ExportInput` + `ExportError` | S | `swift build` |
| 2. `MarkdownExporter` | S | `swift test --filter MarkdownExporter` |
| 3. `DocxExporter` | M | `swift test --filter DocxExporter` + manual Word/Pages open |
| 4. `ExportInputBuilder` (fixtures + collapsing logic) | M | `swift test --filter ExportInputBuilder` |
| 5. `ExportService` (I/O + fallback) | S | `swift test --filter ExportService` |
| 6. UI integration (Menu + NSSavePanel + Copy) | M | xcodebuild + manual click-through |
| 7. Manual verification + polish | S | full `swift test`, manual meeting-length export |

---

### Task 1: `HarcExport` scaffold + `ExportInput` + `ExportError`

**Effort:** S

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInput.swift`
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportError.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputTests.swift`

- [ ] **Step 1: Add the targets to `Package.swift`**

Under `products`, append:
```swift
        .library(name: "HarcExport", targets: ["HarcExport"]),
```
Under `targets`, append:
```swift
        .target(
            name: "HarcExport",
            dependencies: ["HarcCore", "HarcStore"]
        ),
        .testTarget(
            name: "HarcExportTests",
            dependencies: ["HarcExport", "HarcCore", "HarcStore"],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 2: Write `ExportInput.swift`**

```swift
import Foundation

/// Neutral input shape consumed by every exporter. Renderers are pure
/// functions over this type — no filesystem, no AppKit, no GRDB.
public struct ExportInput: Equatable, Sendable {
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Int?
    public let segments: [Segment]

    public init(title: String, startedAt: Date, durationSeconds: Int?, segments: [Segment]) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
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

- [ ] **Step 3: Write `ExportError.swift`**

```swift
import Foundation

public enum ExportError: Error, Sendable {
    case transcriptJSONUnreadable(path: String, underlying: String)
    case docxRenderFailed(underlying: String)
    case writeFailed(url: URL, underlying: String)
    case permissionDenied(url: URL)
    case diskFull
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transcriptJSONUnreadable(let path, _):
            return "Couldn't read transcript JSON at \(path)."
        case .docxRenderFailed:
            return "Couldn't render DOCX. Try Markdown instead."
        case .writeFailed(let url, _):
            return "Couldn't write to \(url.path)."
        case .permissionDenied(let url):
            return "No permission to write to \(url.path)."
        case .diskFull:
            return "Not enough disk space for the export."
        }
    }
}
```

- [ ] **Step 4: Write `ExportInputTests.swift`**

```swift
import Testing
import Foundation
@testable import HarcExport

@Suite("ExportInput")
struct ExportInputTests {
    @Test("isDiarized true when any segment has a speaker id")
    func detectsDiarized() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: [
                .init(speaker: nil, text: "hi"),
                .init(speaker: 1, text: "there"),
            ]
        )
        #expect(input.isDiarized)
    }

    @Test("isDiarized false when all segments are speaker-nil")
    func detectsPlain() {
        let input = ExportInput(
            title: "t", startedAt: Date(), durationSeconds: 0,
            segments: [.init(speaker: nil, text: "a paragraph")]
        )
        #expect(!input.isDiarized)
    }
}
```

- [ ] **Step 5: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test --filter HarcExportTests 2>&1 | tail -10
```

Expected: clean build, 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/HarcExport Tests/HarcExportTests
git commit -m "feat: HarcExport module + ExportInput + ExportError scaffold"
```

---

### Task 2: `MarkdownExporter` + tests

**Effort:** S · **Depends on:** Task 1

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/MarkdownExporter.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/MarkdownExporterTests.swift`

- [ ] **Step 1: Write `MarkdownExporter.swift`**

```swift
import Foundation

/// Renders an `ExportInput` to a minimal Markdown string.
///
/// Shape:
///   - Diarized input: `Speaker N: <text>` one line per segment.
///   - No-diarization input: plain paragraph(s), no prefix.
///
/// Deliberately does NOT escape `*`, `_`, `` ` ``, `[`, `#` — speech
/// transcripts use these naturally ("C#", "*must*", "#design"), and
/// over-escaping hurts downstream LLM parses more than it helps.
public enum MarkdownExporter {
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
        // Trim trailing whitespace/newlines to a single \n.
        while out.hasSuffix("\n") || out.hasSuffix(" ") {
            out.removeLast()
        }
        if !out.isEmpty { out += "\n" }
        return out
    }

    /// Strip control chars (except \n, \t), normalise line endings, trim.
    private static func sanitize(_ s: String) -> String {
        let normalised = s.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n")
        let filtered = normalised.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }     // tab, newline
            if v < 0x20 { return false }                   // other control
            return true
        }
        return String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Write `MarkdownExporterTests.swift`**

```swift
import Testing
import Foundation
@testable import HarcExport

@Suite("MarkdownExporter")
struct MarkdownExporterTests {
    private func input(segments: [ExportInput.Segment]) -> ExportInput {
        ExportInput(title: "t", startedAt: Date(), durationSeconds: nil, segments: segments)
    }

    @Test("diarized: speaker-prefixed flat lines")
    func diarized() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "We should ship this next week."),
            .init(speaker: 1, text: "Agreed, let's scope the dependencies."),
            .init(speaker: 0, text: "I'll file the tickets tonight."),
        ]))
        #expect(result == """
            Speaker 1: We should ship this next week.
            Speaker 2: Agreed, let's scope the dependencies.
            Speaker 1: I'll file the tickets tonight.
            
            """)
    }

    @Test("zero speakers: plain paragraph, no prefix")
    func plain() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: nil, text: "A run-on paragraph with no turns."),
        ]))
        #expect(result == "A run-on paragraph with no turns.\n")
    }

    @Test("single speaker still prefixed")
    func singleSpeaker() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 2, text: "Solo."),
        ]))
        #expect(result == "Speaker 3: Solo.\n")
    }

    @Test("empty segments → empty output")
    func empty() {
        #expect(MarkdownExporter.render(input(segments: [])) == "")
    }

    @Test("special chars pass through unescaped")
    func specialCharsPassThrough() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "I love C# and *bold* text and #channels."),
        ]))
        #expect(result.contains("C# and *bold* text and #channels"))
    }

    @Test("\\r\\n normalised to \\n")
    func crlfNormalised() {
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: 0, text: "line 1\r\nline 2"),
        ]))
        #expect(!result.contains("\r"))
    }

    @Test("control chars stripped")
    func controlCharsStripped() {
        let text = "hello\u{0000}\u{0001}world"
        let result = MarkdownExporter.render(input(segments: [
            .init(speaker: nil, text: text),
        ]))
        #expect(result.contains("helloworld"))
        #expect(!result.contains("\u{0000}"))
    }
}
```

- [ ] **Step 3: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter MarkdownExporterTests 2>&1 | tail -10
```

Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcExport/MarkdownExporter.swift Tests/HarcExportTests/MarkdownExporterTests.swift
git commit -m "feat: MarkdownExporter — minimal speaker-prefixed Markdown"
```

---

### Task 3: `DocxExporter` + tests

**Effort:** M · **Depends on:** Task 1

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/DocxExporter.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/DocxExporterTests.swift`

- [ ] **Step 1: Write `DocxExporter.swift`**

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Renders an `ExportInput` to an Office Open XML (.docx) byte stream
/// using `NSAttributedString.data(from:documentAttributes:)`.
///
/// See the design doc for why this native path was chosen over a
/// third-party OOXML writer.
public enum DocxExporter {
#if canImport(AppKit)
    public static func render(_ input: ExportInput) throws -> Data {
        let attributed = buildAttributedString(input)
        let range = NSRange(location: 0, length: attributed.length)
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML
        ]
        do {
            return try attributed.data(from: range, documentAttributes: attrs)
        } catch {
            throw ExportError.docxRenderFailed(underlying: error.localizedDescription)
        }
    }

    private static func buildAttributedString(_ input: ExportInput) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Title.
        let titleFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
        out.append(NSAttributedString(
            string: input.title + "\n",
            attributes: [.font: titleFont]
        ))

        // Metadata line.
        let metaFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var meta = df.string(from: input.startedAt)
        if let secs = input.durationSeconds, secs > 0 {
            let m = secs / 60, s = secs % 60
            meta += "  ·  \(m)m \(s)s"
        }
        out.append(NSAttributedString(
            string: meta + "\n\n",
            attributes: [
                .font: metaFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))

        // Body paragraph style.
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.lineHeightMultiple = 1.15

        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        for segment in input.segments {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let speaker = segment.speaker {
                out.append(NSAttributedString(
                    string: "Speaker \(speaker + 1): ",
                    attributes: [
                        .font: labelFont,
                        .paragraphStyle: para
                    ]
                ))
                out.append(NSAttributedString(
                    string: segment.text + "\n",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: para
                    ]
                ))
            } else {
                out.append(NSAttributedString(
                    string: segment.text + "\n",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: para
                    ]
                ))
            }
        }
        return out
    }
#else
    public static func render(_ input: ExportInput) throws -> Data {
        throw ExportError.docxRenderFailed(underlying: "AppKit unavailable on this platform")
    }
#endif
}
```

- [ ] **Step 2: Write `DocxExporterTests.swift`**

```swift
import Testing
import Foundation
@testable import HarcExport

@Suite("DocxExporter")
struct DocxExporterTests {
    private func input(segments: [ExportInput.Segment]) -> ExportInput {
        ExportInput(
            title: "Team sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 125,
            segments: segments
        )
    }

    @Test("produces a non-empty docx with ZIP magic bytes")
    func producesZipBytes() throws {
        let data = try DocxExporter.render(input(segments: [
            .init(speaker: 0, text: "Hello."),
            .init(speaker: 1, text: "Hi."),
        ]))
        #expect(data.count > 100)
        // .docx is a ZIP — first four bytes must be PK\x03\x04.
        let head = Array(data.prefix(4))
        #expect(head == [0x50, 0x4B, 0x03, 0x04])
    }

    @Test("empty segments still produces a valid docx")
    func emptyIsValid() throws {
        let data = try DocxExporter.render(input(segments: []))
        #expect(data.count > 100)
        let head = Array(data.prefix(4))
        #expect(head == [0x50, 0x4B, 0x03, 0x04])
    }

    @Test("plain-text round-trip preserves content")
    func roundTripContent() throws {
        let data = try DocxExporter.render(input(segments: [
            .init(speaker: 0, text: "Ship it."),
        ]))
        // Read back via NSAttributedString to confirm the file is well-formed.
        var docAttrs: NSDictionary? = nil
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: &docAttrs
        )
        #expect(decoded.string.contains("Ship it."))
        #expect(decoded.string.contains("Speaker 1"))
    }
}
```

- [ ] **Step 3: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter DocxExporterTests 2>&1 | tail -15
```

Expected: 3 tests pass. **If the round-trip test fails** (common when `officeOpenXML` silently produces `.doc` binary on some macOS releases), check the actual first four bytes of `data` — if they are anything other than `PK\x03\x04`, flag the issue and switch `documentType` to `.rtf` for v1 per the design doc's fallback. Update the test ZIP-magic assertion to the RTF header `{\rtf1` in that case.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcExport/DocxExporter.swift Tests/HarcExportTests/DocxExporterTests.swift
git commit -m "feat: DocxExporter via NSAttributedString.officeOpenXML"
```

---

### Task 4: `ExportInputBuilder` (JSON → ExportInput)

**Effort:** M · **Depends on:** Task 1

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportInputBuilder.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/Fixtures/three-speakers.json`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/Fixtures/single-speaker.json`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/Fixtures/no-diarization.json`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportInputBuilderTests.swift`

- [ ] **Step 1: Write `ExportInputBuilder.swift`**

```swift
import Foundation
import HarcClient
import HarcCore
import HarcStore

/// Builds an `ExportInput` from a `Recording` by loading the on-disk
/// `SessionTranscript` JSON and collapsing words into speaker-attributed
/// segments. Falls back to `Recording.transcriptText` when the JSON is
/// missing or unreadable.
public enum ExportInputBuilder {
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
                    segments: segments
                )
            }
        }

        // Fallback: just the plain transcript text as one segment.
        if let text = recording.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ExportInput(
                title: title,
                startedAt: recording.startedAt,
                durationSeconds: duration,
                segments: [.init(speaker: nil, text: text)]
            )
        }

        return ExportInput(
            title: title,
            startedAt: recording.startedAt,
            durationSeconds: duration,
            segments: []
        )
    }

    /// Collapse `words` + `speakers` into contiguous same-speaker segments.
    /// If `speakers` is empty, emit a single `speaker: nil` segment.
    static func collapseToSegments(transcript: SessionTranscript) -> [ExportInput.Segment] {
        guard !transcript.speakers.isEmpty else {
            let t = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [.init(speaker: nil, text: t)]
        }

        // Assign each word to the speaker whose [startMs, endMs] contains
        // the word's midpoint. Words with no containing speaker segment
        // inherit the previous speaker (avoids fragmenting on brief gaps).
        var currentSpeaker: Int? = nil
        var bucketText = ""
        var output: [ExportInput.Segment] = []

        func flush() {
            let t = bucketText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                output.append(.init(speaker: currentSpeaker, text: t))
            }
            bucketText = ""
        }

        for word in transcript.words {
            let midpoint = (word.startMs + word.endMs) / 2
            let assigned = transcript.speakers.first { seg in
                midpoint >= seg.startMs && midpoint < seg.endMs
            }?.speaker ?? currentSpeaker

            if assigned != currentSpeaker {
                flush()
                currentSpeaker = assigned
            }
            if !bucketText.isEmpty { bucketText += " " }
            bucketText += word.text
        }
        flush()

        // Last-resort: if no words at all, use joinedText as a single
        // segment attributed to the first speaker.
        if output.isEmpty {
            let t = transcript.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                output.append(.init(
                    speaker: transcript.speakers.first?.speaker,
                    text: t
                ))
            }
        }
        return output
    }
}
```

- [ ] **Step 2: Add `HarcClient` to `HarcExport` dependencies**

`SessionTranscript` lives in `HarcClient`. Update `Package.swift`:
```swift
        .target(
            name: "HarcExport",
            dependencies: ["HarcCore", "HarcClient", "HarcStore"]
        ),
```
And the test target:
```swift
        .testTarget(
            name: "HarcExportTests",
            dependencies: ["HarcExport", "HarcCore", "HarcClient", "HarcStore"],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 3: Write fixtures**

`three-speakers.json`:
```json
{
  "audioPath": "/tmp/fake.wav",
  "chunks": [],
  "endedAt": 1700000060,
  "joinedText": "Hello there friend howdy partner",
  "speakers": [
    {"endMs": 2000, "speaker": 0, "startMs": 0},
    {"endMs": 4000, "speaker": 1, "startMs": 2000},
    {"endMs": 6000, "speaker": 2, "startMs": 4000}
  ],
  "startedAt": 1700000000,
  "words": [
    {"endMs": 500, "startMs": 0, "text": "Hello"},
    {"endMs": 1800, "startMs": 500, "text": "there"},
    {"endMs": 2500, "startMs": 2000, "text": "friend"},
    {"endMs": 3800, "startMs": 2500, "text": "howdy"},
    {"endMs": 5000, "startMs": 4000, "text": "partner"}
  ]
}
```

`single-speaker.json`:
```json
{
  "audioPath": "/tmp/fake.wav",
  "chunks": [],
  "endedAt": 1700000010,
  "joinedText": "All me talking here",
  "speakers": [
    {"endMs": 10000, "speaker": 0, "startMs": 0}
  ],
  "startedAt": 1700000000,
  "words": [
    {"endMs": 500, "startMs": 0, "text": "All"},
    {"endMs": 1000, "startMs": 500, "text": "me"},
    {"endMs": 1500, "startMs": 1000, "text": "talking"},
    {"endMs": 2000, "startMs": 1500, "text": "here"}
  ]
}
```

`no-diarization.json`:
```json
{
  "audioPath": "/tmp/fake.wav",
  "chunks": [],
  "endedAt": 1700000010,
  "joinedText": "No speakers here just text",
  "speakers": [],
  "startedAt": 1700000000,
  "words": []
}
```

- [ ] **Step 4: Write `ExportInputBuilderTests.swift`**

```swift
import Testing
import Foundation
import HarcStore
@testable import HarcExport

@Suite("ExportInputBuilder")
struct ExportInputBuilderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try #require(url)
    }

    @Test("three speakers → three collapsed segments in order")
    func threeSpeakers() throws {
        let url = try fixtureURL("three-speakers")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060)
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.isDiarized)
        #expect(input.segments.count == 3)
        #expect(input.segments[0].speaker == 0)
        #expect(input.segments[1].speaker == 1)
        #expect(input.segments[2].speaker == 2)
        #expect(input.segments[0].text.contains("Hello"))
    }

    @Test("single-speaker JSON still emits attributed segments")
    func singleSpeaker() throws {
        let url = try fixtureURL("single-speaker")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == 0)
    }

    @Test("empty speakers array → single nil-speaker segment with joinedText")
    func noDiarization() throws {
        let url = try fixtureURL("no-diarization")
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: url.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(!input.isDiarized)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == nil)
        #expect(input.segments[0].text == "No speakers here just text")
    }

    @Test("missing JSON with transcriptText → fallback single segment")
    func fallbackToTranscriptText() {
        let rec = Recording(
            wavPath: "/tmp/fake.wav",
            jsonPath: "/tmp/does-not-exist.json",
            startedAt: Date(),
            transcriptText: "plain fallback text"
        )
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.count == 1)
        #expect(input.segments[0].speaker == nil)
        #expect(input.segments[0].text == "plain fallback text")
    }

    @Test("missing JSON and nil transcriptText → empty segments")
    func totallyEmpty() {
        let rec = Recording(wavPath: "/tmp/fake.wav", startedAt: Date())
        let input = ExportInputBuilder.build(from: rec)
        #expect(input.segments.isEmpty)
    }
}
```

- [ ] **Step 5: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -5
swift test --filter ExportInputBuilderTests 2>&1 | tail -15
```

Expected: clean build, 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/HarcExport/ExportInputBuilder.swift \
        Tests/HarcExportTests/Fixtures Tests/HarcExportTests/ExportInputBuilderTests.swift
git commit -m "feat: ExportInputBuilder — SessionTranscript → speaker-attributed segments"
```

---

### Task 5: `ExportService` I/O façade

**Effort:** S · **Depends on:** Tasks 2, 3, 4

**Files:**
- Create: `/Users/jlane/GitHub/Harc/Sources/HarcExport/ExportService.swift`
- Create: `/Users/jlane/GitHub/Harc/Tests/HarcExportTests/ExportServiceTests.swift`

- [ ] **Step 1: Write `ExportService.swift`**

```swift
import Foundation
import HarcStore

public enum ExportFormat: Sendable {
    case markdown
    case docx

    public var filenameExtension: String {
        switch self {
        case .markdown: return "md"
        case .docx:     return "docx"
        }
    }
}

/// Thin façade over renderers + filesystem. UI calls these; renderers stay
/// pure and testable.
public enum ExportService {
    /// Default destination: same folder and stem as the recording's .wav,
    /// with the format's extension. Caller may override via NSSavePanel.
    public static func defaultDestination(for recording: Recording, format: ExportFormat) -> URL {
        let wav = URL(fileURLWithPath: recording.wavPath)
        let stem = wav.deletingPathExtension().lastPathComponent
        return wav.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(format.filenameExtension)")
    }

    /// Render + write to `url`. Atomic write. Caller is responsible for
    /// any overwrite confirmation (NSSavePanel handles it natively).
    public static func write(
        recording: Recording,
        format: ExportFormat,
        to url: URL
    ) throws {
        let input = ExportInputBuilder.build(from: recording)
        let data: Data
        switch format {
        case .markdown:
            data = Data(MarkdownExporter.render(input).utf8)
        case .docx:
            data = try DocxExporter.render(input)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileWriteOutOfSpaceError:
                    throw ExportError.diskFull
                case NSFileWriteNoPermissionError:
                    throw ExportError.permissionDenied(url: url)
                default:
                    break
                }
            }
            throw ExportError.writeFailed(url: url, underlying: error.localizedDescription)
        }
    }

    /// Render Markdown only, return the string. For the "Copy Markdown" UI.
    public static func markdownString(for recording: Recording) -> String {
        let input = ExportInputBuilder.build(from: recording)
        return MarkdownExporter.render(input)
    }
}
```

- [ ] **Step 2: Write `ExportServiceTests.swift`**

```swift
import Testing
import Foundation
import HarcStore
@testable import HarcExport

@Suite("ExportService")
struct ExportServiceTests {
    @Test("defaultDestination uses the wav stem + format ext")
    func defaultDestination() {
        let rec = Recording(
            wavPath: "/tmp/harc/2026/2026-04-19/10-00-00.wav",
            startedAt: Date()
        )
        let md = ExportService.defaultDestination(for: rec, format: .markdown)
        let dx = ExportService.defaultDestination(for: rec, format: .docx)
        #expect(md.path == "/tmp/harc/2026/2026-04-19/10-00-00.md")
        #expect(dx.path == "/tmp/harc/2026/2026-04-19/10-00-00.docx")
    }

    @Test("writes a Markdown file to the given url")
    func writesMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = Recording(
            wavPath: tmp.appendingPathComponent("x.wav").path,
            startedAt: Date(),
            transcriptText: "hello world"
        )
        let target = tmp.appendingPathComponent("x.md")
        try ExportService.write(recording: rec, format: .markdown, to: target)
        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(contents.contains("hello world"))
    }

    @Test("markdownString returns the renderer output")
    func markdownString() {
        let rec = Recording(
            wavPath: "/tmp/x.wav",
            startedAt: Date(),
            transcriptText: "clipboard paste"
        )
        let s = ExportService.markdownString(for: rec)
        #expect(s.contains("clipboard paste"))
    }
}
```

- [ ] **Step 3: Build + test**

```bash
cd /Users/jlane/GitHub/Harc
swift test --filter ExportServiceTests 2>&1 | tail -10
swift test 2>&1 | tail -10
```

Expected: 3 new tests pass; full suite still green.

- [ ] **Step 4: Commit**

```bash
git add Sources/HarcExport/ExportService.swift Tests/HarcExportTests/ExportServiceTests.swift
git commit -m "feat: ExportService — render+write façade with typed I/O errors"
```

---

### Task 6: UI integration — Export menu + Save panel + Copy

**Effort:** M · **Depends on:** Task 5

**Files:**
- Modify: `/Users/jlane/GitHub/Harc/Package.swift` (add HarcExport to HarcUI deps)
- Modify: `/Users/jlane/GitHub/Harc/Sources/HarcUI/LibraryWindowRootView.swift`

- [ ] **Step 1: Add HarcExport to HarcUI's dependencies**

```swift
        .target(
            name: "HarcUI",
            dependencies: [
                "HarcCore",
                "HarcAudio",
                "HarcClient",
                "HarcStore",
                "HarcExport",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
```

- [ ] **Step 2: Add the Export UI to `detailContent`**

In `LibraryWindowRootView.swift`, add `import HarcExport` at the top, alongside the existing `import HarcStore`.

Insert a new `exportControls(for:)` helper and call it from `detailContent(for:)`, placed below the "AI SUMMARY" block and above `Spacer(minLength: 0)`:

```swift
    @State private var exportErrorMessage: String?

    private func exportControls(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("EXPORT")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .tracking(1.2)
            HStack(spacing: HarcDesign.Space.sm) {
                Menu {
                    Button("Export Markdown…") { runExport(rec, format: .markdown) }
                    Button("Export DOCX…")     { runExport(rec, format: .docx) }
                    Divider()
                    Button("Copy Markdown")    { copyMarkdown(rec) }
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
                    copyMarkdown(rec)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Copy Markdown")
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

    private func runExport(_ rec: Recording, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService
            .defaultDestination(for: rec, format: format)
            .lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: rec.wavPath).deletingLastPathComponent()
        if let contentType = UTType(filenameExtension: format.filenameExtension) {
            panel.allowedContentTypes = [contentType]
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ExportService.write(recording: rec, format: format, to: url)
                exportErrorMessage = nil
            } catch {
                exportErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func copyMarkdown(_ rec: Recording) {
        let md = ExportService.markdownString(for: rec)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
        exportErrorMessage = nil
    }
```

Add `import UniformTypeIdentifiers` to the top of the file for `UTType`.

Call it from `detailContent(for:)`:
```swift
                exportControls(for: rec)
```
(place after the "AI SUMMARY" block.)

- [ ] **Step 3: Build (swift + xcodebuild)**

```bash
cd /Users/jlane/GitHub/Harc
swift build 2>&1 | tail -10
swift test 2>&1 | tail -10
rm -rf Harc.xcodeproj && xcodegen generate 2>&1 | tail -3
xcodebuild -project Harc.xcodeproj -scheme Harc -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -3
```

Expected: clean builds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/HarcUI/LibraryWindowRootView.swift
git commit -m "feat: Library — Export menu (Markdown/DOCX) + Copy Markdown"
```

---

### Task 7: End-to-end manual verification

**Effort:** S · **Depends on:** Task 6

- [ ] **Step 1: Run the app against a real recording**

```bash
cd /Users/jlane/GitHub/Harc
rm -rf Harc.xcodeproj && xcodegen generate
open Harc.xcodeproj
```

Build + run from Xcode. Open the Library window on an existing recording that has a `.json` sibling (prefer a diarized one).

- [ ] **Step 2: Markdown export**

Click Export → Export Markdown…. Accept the default filename in the sibling folder. Open the resulting `.md` in any text editor. Expected: `Speaker N: ` prefixed lines, one per turn, no front matter.

- [ ] **Step 3: DOCX export**

Click Export → Export DOCX…. Save. Open the `.docx` in **Word** AND **Pages** AND **TextEdit**. Expected: title at top in bold, metadata line below, speaker labels bold and inline with their text. If any of the three renderers shows garbled output, follow the fallback path in the design doc (switch `DocxExporter` to `.rtf` with a rename of the extension, or file the issue and narrow scope).

- [ ] **Step 4: Copy Markdown**

Click Copy Markdown. Paste into a scratch app (e.g. Notes or a text field) and confirm identical content to the `.md` export.

- [ ] **Step 5: Error path spot check**

Try exporting to a folder you don't have write access to (e.g. `/System/harc.md`). Confirm the red error string appears in the detail pane.

- [ ] **Step 6: Full-suite green light**

```bash
cd /Users/jlane/GitHub/Harc
swift test 2>&1 | tail -10
swift build -Xswiftc -strict-concurrency=complete 2>&1 | tail -10
```

Expected: all tests pass, no strict-concurrency regressions.

- [ ] **Step 7: Final commit (only if polish changes were needed)**

If manual testing surfaced small tweaks (copy wording, padding, an icon change), squash them into a final commit. Otherwise this task is just verification — no commit needed.

---

## Acceptance criteria

- New `HarcExport` module with pure, unit-tested `MarkdownExporter`, `DocxExporter`, `ExportInputBuilder`, and `ExportService`.
- Library detail pane exposes `Export ▾` (Markdown / DOCX / Copy Markdown) + a direct Copy Markdown button.
- Default destination is the recording's sibling folder with `HH-mm-ss.{md,docx}`; `NSSavePanel` allows override.
- Disk-full / permission-denied / render failures surface as a red inline error; `NSSavePanel` handles overwrite confirm.
- `swift test` green, `swift build -Xswiftc -strict-concurrency=complete` clean, `xcodebuild` green.
- Manual: `.docx` opens cleanly in Word, Pages, TextEdit. `.md` copy-paste into an LLM produces speaker-attributed input.

## Out of scope (design doc §2)

- SRT/VTT, batch export, PDF, RTF, user-editable speaker names, auto-export on stop, YAML front matter.
