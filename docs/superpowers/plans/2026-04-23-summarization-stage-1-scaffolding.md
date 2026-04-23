# Summarization Stage 1 — Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the pure-Swift scaffolding for the summarization feature — value types, prompt builder, and parser — with no MLX dependency, no DB migration, and no app integration. After this stage `swift test` passes a new HarcSummarizeTests target end-to-end.

**Architecture:** A new SwiftPM library target `HarcSummarize` that depends only on `HarcCore`. Holds three things: input/output value types (`PromptTranscript`, `ActionItem`, `SummaryParseResult`, `SummaryOutput`); a `SummaryPrompt` enum that builds the Gemma-bound prompt string from a `PromptTranscript` (head-truncating when the body exceeds a word budget); and a `SummaryParser` enum that turns Gemma's response back into structured output. Stage 2 will introduce `mlx-swift` and `SummarizerService`; Stage 3 wires persistence; Stage 4 adds UI. Stage 1 ships nothing user-visible — its job is to land the testable shapes that later stages plug into.

**Tech Stack:** Swift 6, SwiftPM, XCTest. No new external packages.

**Spec reference:** `docs/superpowers/specs/2026-04-22-local-summarization-design.md` §2 (scope), §5 (prompt + parser), §11 Stage 1.

---

## File Structure

**Files created in this plan:**

| Path | Purpose |
|---|---|
| `Sources/HarcSummarize/PromptTranscript.swift` | Input value type — list of `(speaker?, text)` utterances. |
| `Sources/HarcSummarize/SummaryOutput.swift` | Output value types: `ActionItem`, `SummaryParseResult`, `SummaryOutput`. |
| `Sources/HarcSummarize/SummaryPrompt.swift` | `enum SummaryPrompt` — template constant + `build(transcript:budgetWords:)` with head-truncation. |
| `Sources/HarcSummarize/SummaryParser.swift` | `enum SummaryParser` — `parse(_:)` from raw model output to `SummaryParseResult`. |
| `Tests/HarcSummarizeTests/SummaryOutputTests.swift` | Codable round-trip tests for the output value types. |
| `Tests/HarcSummarizeTests/SummaryPromptTests.swift` | Render tests: multi-speaker, solo, head-truncation. |
| `Tests/HarcSummarizeTests/SummaryParserTests.swift` | Parser branches: happy path, no items, malformed, actor + due, no actor, stray prose. |

**Files modified:**

| Path | Change |
|---|---|
| `Package.swift` | Add `HarcSummarize` library target (deps: `HarcCore`) and `HarcSummarizeTests` test target. |

---

## Task 1: Scaffold the SwiftPM target

**Files:**
- Create: `Sources/HarcSummarize/HarcSummarize.swift` (placeholder so the target has at least one source file)
- Modify: `Package.swift` (add target + test target + library product)

- [ ] **Step 1: Create the placeholder source file**

Create `Sources/HarcSummarize/HarcSummarize.swift` with:

```swift
// Umbrella file for the HarcSummarize target. Real code lives in the
// sibling files in this directory. Kept here so the target has at least
// one source even before the rest of Stage 1 lands.
```

- [ ] **Step 2: Edit `Package.swift` to add the target, test target, and product**

Find the `products:` array in `Package.swift` and add `HarcSummarize` to it:

```swift
.library(name: "HarcSummarize", targets: ["HarcSummarize"]),
```

Find the `targets:` array. Add the new target alongside the others (after `HarcMeetingDetect` is fine):

```swift
.target(
    name: "HarcSummarize",
    dependencies: ["HarcCore"]
),
```

Add the test target near the bottom of the `targets:` array (alongside the other `.testTarget` entries):

```swift
.testTarget(
    name: "HarcSummarizeTests",
    dependencies: ["HarcSummarize", "HarcCore"]
),
```

- [ ] **Step 3: Build to verify the package resolves**

Run: `swift build`

Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/HarcSummarize/HarcSummarize.swift
git commit -m "$(cat <<'EOF'
feat(summarize): scaffold HarcSummarize target

Empty target + matching test target. Real types and logic land in
follow-up commits in Stage 1 of the summarization spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Output value types — `ActionItem`, `SummaryParseResult`, `SummaryOutput`

**Files:**
- Create: `Sources/HarcSummarize/SummaryOutput.swift`
- Create: `Tests/HarcSummarizeTests/SummaryOutputTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HarcSummarizeTests/SummaryOutputTests.swift`:

```swift
import XCTest
@testable import HarcSummarize

final class SummaryOutputTests: XCTestCase {

    func test_actionItem_codableRoundTrip() throws {
        let original = ActionItem(
            text: "rewrite tiering page",
            actor: "Jason",
            due: "Friday",
            done: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_summaryParseResult_holdsSummaryItemsAndWarning() {
        let result = SummaryParseResult(
            summary: "The team reviewed the roadmap.",
            actionItems: [
                ActionItem(text: "follow up on pricing", actor: "Amy", due: nil, done: false)
            ],
            parseWarning: false
        )
        XCTAssertEqual(result.summary, "The team reviewed the roadmap.")
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.actionItems[0].actor, "Amy")
        XCTAssertFalse(result.parseWarning)
    }

    func test_summaryOutput_codableRoundTrip() throws {
        let original = SummaryOutput(
            summary: "Three sentences here.",
            actionItems: [
                ActionItem(text: "ship it", actor: nil, due: nil, done: false)
            ],
            model: "gemma-4-e2b-it-4bit",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            elapsedMs: 24_500,
            sourceWordCount: 8_200,
            parseWarning: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SummaryOutput.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SummaryOutputTests`

Expected: build error — `ActionItem`, `SummaryParseResult`, `SummaryOutput` undefined.

- [ ] **Step 3: Write the types**

Create `Sources/HarcSummarize/SummaryOutput.swift`:

```swift
import Foundation

/// One row in the action-items section of a generated summary. The user
/// can toggle `done` from the SummaryCardView (Stage 4); the rest is
/// produced by `SummaryParser` and never edited after generation.
public struct ActionItem: Codable, Equatable, Sendable {
    public var text: String
    public var actor: String?
    public var due: String?
    public var done: Bool

    public init(text: String, actor: String? = nil, due: String? = nil, done: Bool = false) {
        self.text = text
        self.actor = actor
        self.due = due
        self.done = done
    }
}

/// What `SummaryParser.parse(_:)` returns — the structured pieces it
/// could pull out of a raw model response. Caller (Stage 2's
/// `SummarizerService`) wraps this into a full `SummaryOutput` with
/// metadata it owns (model id, timing, source word count).
public struct SummaryParseResult: Equatable, Sendable {
    public let summary: String
    public let actionItems: [ActionItem]
    /// True when the model didn't emit the expected `## Summary` /
    /// `## Action Items` shape. The view shows an `ⓘ` tooltip and
    /// surfaces the raw text in `summary`.
    public let parseWarning: Bool

    public init(summary: String, actionItems: [ActionItem], parseWarning: Bool) {
        self.summary = summary
        self.actionItems = actionItems
        self.parseWarning = parseWarning
    }
}

/// Persisted summary for a recording. Stored across the four new
/// columns added in Stage 3's `v7_summary` migration.
public struct SummaryOutput: Codable, Equatable, Sendable {
    public let summary: String
    public let actionItems: [ActionItem]
    public let model: String          // ModelDescriptor.id, e.g. "gemma-4-e2b-it-4bit"
    public let generatedAt: Date
    public let elapsedMs: Int
    /// Transcript word count at generation time. Drives the staleness
    /// nudge in SummaryCardView (§7.2): if the current transcript
    /// differs by >5 %, the card shows a "regenerate?" banner.
    public let sourceWordCount: Int
    public let parseWarning: Bool

    public init(
        summary: String,
        actionItems: [ActionItem],
        model: String,
        generatedAt: Date,
        elapsedMs: Int,
        sourceWordCount: Int,
        parseWarning: Bool
    ) {
        self.summary = summary
        self.actionItems = actionItems
        self.model = model
        self.generatedAt = generatedAt
        self.elapsedMs = elapsedMs
        self.sourceWordCount = sourceWordCount
        self.parseWarning = parseWarning
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SummaryOutputTests`

Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSummarize/SummaryOutput.swift Tests/HarcSummarizeTests/SummaryOutputTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): add output value types

ActionItem, SummaryParseResult, SummaryOutput. Codable round-trip tests
guard the persisted shape ahead of the v7_summary migration that lands
in Stage 3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `PromptTranscript` input type

**Files:**
- Create: `Sources/HarcSummarize/PromptTranscript.swift`
- Modify: `Tests/HarcSummarizeTests/SummaryOutputTests.swift` *(no — separate test file written in next task)*

> Note: `PromptTranscript` has no behavior worth a standalone test today — it's a value type with one initializer. Its tests live in `SummaryPromptTests` (Task 4) which exercise it through `SummaryPrompt.build`. Defining it now keeps Task 4's tests compileable.

- [ ] **Step 1: Write the type**

Create `Sources/HarcSummarize/PromptTranscript.swift`:

```swift
import Foundation

/// Input to `SummaryPrompt.build`. A flat list of utterances; each may
/// carry a speaker label (when diarization is on) or be `nil` for solo
/// dictation. Decoupled from `HarcClient.SessionTranscript` on purpose
/// — Stage 1 doesn't depend on the rest of the audio pipeline; an
/// adapter from `SessionTranscript` ships in Stage 2 alongside the
/// service that consumes it.
public struct PromptTranscript: Equatable, Sendable {
    public struct Utterance: Equatable, Sendable {
        public let speaker: String?
        public let text: String

        public init(speaker: String?, text: String) {
            self.speaker = speaker
            self.text = text
        }
    }

    public let utterances: [Utterance]

    public init(utterances: [Utterance]) {
        self.utterances = utterances
    }
}
```

- [ ] **Step 2: Build to verify the type compiles**

Run: `swift build`

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/HarcSummarize/PromptTranscript.swift
git commit -m "$(cat <<'EOF'
feat(summarize): add PromptTranscript input type

Flat list of (speaker?, text) utterances. Decoupled from
HarcClient.SessionTranscript; an adapter ships in Stage 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `SummaryPrompt.build` — multi-speaker rendering

**Files:**
- Create: `Sources/HarcSummarize/SummaryPrompt.swift`
- Create: `Tests/HarcSummarizeTests/SummaryPromptTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HarcSummarizeTests/SummaryPromptTests.swift`:

```swift
import XCTest
@testable import HarcSummarize

final class SummaryPromptTests: XCTestCase {

    func test_build_multiSpeaker_producesLabeledLinesAndTemplate() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Welcome everyone."),
            .init(speaker: "Amy", text: "Hi all."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)

        XCTAssertTrue(prompt.contains("Jason: Welcome everyone."),
            "Speaker-labeled line should appear verbatim.")
        XCTAssertTrue(prompt.contains("Amy: Hi all."),
            "Second speaker line should appear verbatim.")
        XCTAssertTrue(prompt.contains("## Summary"),
            "Template's ## Summary section header must be in the prompt.")
        XCTAssertTrue(prompt.contains("## Action Items"),
            "Template's ## Action Items section header must be in the prompt.")
        XCTAssertFalse(prompt.contains("{TRANSCRIPT}"),
            "Placeholder must be replaced.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SummaryPromptTests`

Expected: build error — `SummaryPrompt` undefined.

- [ ] **Step 3: Implement `SummaryPrompt.build`**

Create `Sources/HarcSummarize/SummaryPrompt.swift`:

```swift
import Foundation

/// Builds the Gemma-bound prompt string. Pure — given the same
/// transcript + budget, returns the same string. No model state,
/// no I/O. The MLX caller (Stage 2) wraps the chat-template shell
/// around this body via the tokenizer, not via this code.
public enum SummaryPrompt {

    /// The user-turn body sent to Gemma. `{TRANSCRIPT}` is replaced
    /// at build time with the rendered utterance lines.
    public static let template: String = """
    You analyze meeting transcripts and produce a short, factual summary plus
    action items.

    Output EXACTLY this format:

    ## Summary
    <3–6 sentences, plain prose, no bullets, no headings inside>

    ## Action Items
    - [ ] <actor>: <task> (<due if mentioned>)
    - [ ] <actor>: <task>

    If no action items are in the transcript, write:
    ## Action Items
    _None identified._

    Rules:
    - Never invent facts. If something isn't said, don't add it.
    - Use speaker names where present in the transcript; fall back to "the team" or "someone".
    - Action items are the MINIMUM — only include items someone actually committed to.

    Transcript:
    <<<
    {TRANSCRIPT}
    >>>
    """

    /// Build the full prompt. If the rendered body exceeds `budgetWords`,
    /// drop whole utterances from the front and prepend
    /// `[Earlier in the meeting…]` so the model knows context is missing.
    public static func build(transcript: PromptTranscript, budgetWords: Int) -> String {
        let body = renderBody(transcript: transcript, budgetWords: budgetWords)
        return template.replacingOccurrences(of: "{TRANSCRIPT}", with: body)
    }

    // MARK: - Internals (visible for tests via @testable)

    static func renderBody(transcript: PromptTranscript, budgetWords: Int) -> String {
        let lines = transcript.utterances.map(line(for:))
        let totalWords = lines.map(wordCount(of:)).reduce(0, +)
        if totalWords <= budgetWords {
            return lines.joined(separator: "\n")
        }
        // Walk from the tail forward, keeping whole utterances until we
        // hit the budget. Preserves speaker boundaries.
        var keptReversed: [String] = []
        var keptWords = 0
        for line in lines.reversed() {
            let w = wordCount(of: line)
            if keptWords + w > budgetWords { break }
            keptReversed.append(line)
            keptWords += w
        }
        let tail = keptReversed.reversed().joined(separator: "\n")
        return "[Earlier in the meeting…]\n" + tail
    }

    static func line(for utt: PromptTranscript.Utterance) -> String {
        if let speaker = utt.speaker, !speaker.isEmpty {
            return "\(speaker): \(utt.text)"
        }
        return utt.text
    }

    static func wordCount(of s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SummaryPromptTests`

Expected: 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSummarize/SummaryPrompt.swift Tests/HarcSummarizeTests/SummaryPromptTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): add SummaryPrompt.build for multi-speaker transcripts

Template + utterance rendering. Head-truncation lives in the same enum
but is not exercised yet — covered in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `SummaryPrompt` — solo dictation + head-truncation

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummaryPromptTests.swift` (add 2 tests)

- [ ] **Step 1: Write the solo-dictation test**

Append to `Tests/HarcSummarizeTests/SummaryPromptTests.swift` inside the existing class:

```swift
    func test_build_soloDictation_omitsSpeakerLabel() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: nil, text: "Note to self: pick up groceries."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)

        XCTAssertTrue(prompt.contains("Note to self: pick up groceries."),
            "Solo utterance must appear verbatim.")
        // No leading-colon artifact — that would mean a missing speaker
        // label rendered as ": Note…" or "nil: Note…".
        XCTAssertFalse(prompt.contains(": Note to self"),
            "Solo line must not be prefixed with a label separator.")
        XCTAssertFalse(prompt.contains("nil:"),
            "nil speaker must never leak into the prompt.")
    }
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `swift test --filter SummaryPromptTests`

Expected: 2 tests passed.

(This case is already handled by the impl in Task 4 — `line(for:)` checks for non-nil non-empty speaker. The test is a regression guard.)

- [ ] **Step 3: Write the head-truncation test**

Append to `Tests/HarcSummarizeTests/SummaryPromptTests.swift`:

```swift
    func test_build_overBudget_headTruncatesWithPrefix() {
        // 100 utterances, each "S0: w1" / "S1: w2" / ... — 2 words per
        // line for the wordCount counter.
        let utterances = (1...100).map { i in
            PromptTranscript.Utterance(speaker: "S\(i % 2)", text: "w\(i)")
        }
        let transcript = PromptTranscript(utterances: utterances)
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 20)

        XCTAssertTrue(prompt.contains("[Earlier in the meeting…]"),
            "Truncated transcripts must announce the cut so the model knows.")
        XCTAssertTrue(prompt.contains("w100"),
            "The tail (most recent utterances) must be retained.")
        XCTAssertFalse(prompt.contains("w1\n"),
            "Early utterances must be dropped (w1 followed by newline).")
        XCTAssertFalse(prompt.contains("w50\n"),
            "Mid-meeting utterances should also be dropped at this budget.")
    }

    func test_build_underBudget_doesNotPrependPrefix() {
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Short meeting."),
        ])
        let prompt = SummaryPrompt.build(transcript: transcript, budgetWords: 1_000)
        XCTAssertFalse(prompt.contains("[Earlier in the meeting…]"),
            "Under-budget transcripts must not announce a (false) cut.")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SummaryPromptTests`

Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Tests/HarcSummarizeTests/SummaryPromptTests.swift
git commit -m "$(cat <<'EOF'
test(summarize): cover solo dictation + head-truncation in SummaryPrompt

Solo-utterance no-label rendering, over-budget head-truncation with
[Earlier in the meeting…] prefix, and the under-budget no-prefix
regression case.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `SummaryParser` — happy path

**Files:**
- Create: `Sources/HarcSummarize/SummaryParser.swift`
- Create: `Tests/HarcSummarizeTests/SummaryParserTests.swift`

- [ ] **Step 1: Write the failing happy-path test**

Create `Tests/HarcSummarizeTests/SummaryParserTests.swift`:

```swift
import XCTest
@testable import HarcSummarize

final class SummaryParserTests: XCTestCase {

    func test_parse_happyPath_extractsSummaryAndThreeActionItems() {
        let raw = """
        ## Summary
        The team reviewed the Q3 roadmap. Amy raised pricing as a blocker.
        Jason agreed to rewrite the tiering page by Friday.

        ## Action Items
        - [ ] Jason: rewrite tiering page (Friday)
        - [ ] Amy: schedule follow-up on pricing
        - [x] Sam: file GDPR ticket
        """
        let result = SummaryParser.parse(raw)

        XCTAssertFalse(result.parseWarning,
            "Well-formed input must not raise the parse warning.")
        XCTAssertTrue(result.summary.hasPrefix("The team reviewed"),
            "Summary should start at the first prose line after ## Summary.")
        XCTAssertFalse(result.summary.contains("## Action Items"),
            "Summary must not bleed into the action-items section.")
        XCTAssertEqual(result.actionItems.count, 3,
            "Three action-item lines should produce three items.")

        XCTAssertEqual(result.actionItems[0].actor, "Jason")
        XCTAssertEqual(result.actionItems[0].text, "rewrite tiering page")
        XCTAssertEqual(result.actionItems[0].due, "Friday")
        XCTAssertFalse(result.actionItems[0].done)

        XCTAssertEqual(result.actionItems[1].actor, "Amy")
        XCTAssertEqual(result.actionItems[1].text, "schedule follow-up on pricing")
        XCTAssertNil(result.actionItems[1].due)

        XCTAssertEqual(result.actionItems[2].actor, "Sam")
        XCTAssertTrue(result.actionItems[2].done,
            "- [x] should produce a done item.")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SummaryParserTests`

Expected: build error — `SummaryParser` undefined.

- [ ] **Step 3: Implement `SummaryParser.parse`**

Create `Sources/HarcSummarize/SummaryParser.swift`:

```swift
import Foundation

/// Turns Gemma's raw model output into a `SummaryParseResult`. Lenient
/// — the spec template asks for a specific shape but the model can
/// drift; the parser handles "extra prose between fences", "no Action
/// Items header at all", and "completely off-script output" by surfacing
/// `parseWarning = true` rather than erroring.
public enum SummaryParser {

    public static func parse(_ raw: String) -> SummaryParseResult {
        // 1. Split on the FIRST `## Summary` header. If absent, the whole
        //    response is treated as the summary text + parseWarning.
        guard let summaryHeader = raw.range(of: "## Summary") else {
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return SummaryParseResult(summary: fallback, actionItems: [], parseWarning: true)
        }

        let afterSummary = raw[summaryHeader.upperBound...]

        // 2. Split on the NEXT `## Action Items`. If absent, everything
        //    after `## Summary` is the summary; no items; warning.
        guard let actionsHeader = afterSummary.range(of: "## Action Items") else {
            let summary = afterSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            return SummaryParseResult(summary: String(summary), actionItems: [], parseWarning: true)
        }

        let summaryText = afterSummary[..<actionsHeader.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionsBody = afterSummary[actionsHeader.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let items = parseActionItems(actionsBody)
        return SummaryParseResult(summary: String(summaryText), actionItems: items, parseWarning: false)
    }

    // MARK: - Internals

    private static let noneIdentifiedMarker = "_none identified._"

    static func parseActionItems(_ body: String) -> [ActionItem] {
        // The "no items" sentinel is case-insensitive; whitespace around
        // it is tolerated.
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == noneIdentifiedMarker {
            return []
        }

        var items: [ActionItem] = []
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Match "- [ ]" or "- [x]" / "- [X]". Anything else is ignored
            // (stray prose between lines, extra fences, etc.).
            let unchecked = "- [ ]"
            let checkedLower = "- [x]"
            let checkedUpper = "- [X]"
            let isUnchecked = line.hasPrefix(unchecked)
            let isChecked = line.hasPrefix(checkedLower) || line.hasPrefix(checkedUpper)
            guard isUnchecked || isChecked else { continue }

            let prefix = isChecked
                ? (line.hasPrefix(checkedLower) ? checkedLower : checkedUpper)
                : unchecked
            let bodyText = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            items.append(parseActionItemBody(bodyText, done: isChecked))
        }
        return items
    }

    static func parseActionItemBody(_ text: String, done: Bool) -> ActionItem {
        var remaining = text
        var due: String? = nil
        var actor: String? = nil

        // Trailing "(...)" → due.
        if remaining.hasSuffix(")"),
           let openParen = remaining.lastIndex(of: "(") {
            let dueRange = remaining.index(after: openParen)..<remaining.index(before: remaining.endIndex)
            due = String(remaining[dueRange]).trimmingCharacters(in: .whitespaces)
            remaining = String(remaining[..<openParen]).trimmingCharacters(in: .whitespaces)
        }

        // Leading "<actor>:" → actor. Heuristic: actor is short and has
        // no commas — guards against parsing "Tuesday, Friday: …" as
        // an actor.
        if let colon = remaining.firstIndex(of: ":") {
            let candidate = String(remaining[..<colon]).trimmingCharacters(in: .whitespaces)
            let words = candidate.split(whereSeparator: { $0.isWhitespace })
            if !candidate.isEmpty, words.count <= 3, !candidate.contains(",") {
                actor = candidate
                remaining = String(remaining[remaining.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return ActionItem(text: remaining, actor: actor, due: due, done: done)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SummaryParserTests`

Expected: 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/HarcSummarize/SummaryParser.swift Tests/HarcSummarizeTests/SummaryParserTests.swift
git commit -m "$(cat <<'EOF'
feat(summarize): add SummaryParser happy path

Lenient header-based split; - [ ] / - [x] line matcher; actor and due
heuristics for the action-item body. Edge cases land in follow-up tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `SummaryParser` — empty action items

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummaryParserTests.swift` (add 1 test)

- [ ] **Step 1: Write the test**

Append to `Tests/HarcSummarizeTests/SummaryParserTests.swift` inside the existing class:

```swift
    func test_parse_noActionItems_returnsEmptyList() {
        let raw = """
        ## Summary
        Quick check-in. No work assigned.

        ## Action Items
        _None identified._
        """
        let result = SummaryParser.parse(raw)

        XCTAssertFalse(result.parseWarning)
        XCTAssertEqual(result.summary, "Quick check-in. No work assigned.")
        XCTAssertTrue(result.actionItems.isEmpty,
            "_None identified._ sentinel must yield zero items.")
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter SummaryParserTests`

Expected: 2 tests passed (the existing happy-path test + this one). Implementation already handles this case via the `noneIdentifiedMarker` check in `parseActionItems`.

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcSummarizeTests/SummaryParserTests.swift
git commit -m "$(cat <<'EOF'
test(summarize): cover _None identified._ branch in SummaryParser

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `SummaryParser` — malformed output

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummaryParserTests.swift` (add 2 tests)

- [ ] **Step 1: Write the no-headers and no-action-items-header tests**

Append to `Tests/HarcSummarizeTests/SummaryParserTests.swift`:

```swift
    func test_parse_noSummaryHeader_setsParseWarningAndKeepsRaw() {
        let raw = "Sometimes the model just talks. No fences, no structure."
        let result = SummaryParser.parse(raw)

        XCTAssertTrue(result.parseWarning,
            "Missing ## Summary header must raise the warning.")
        XCTAssertEqual(result.summary, raw,
            "Raw text is preserved so the user still sees something.")
        XCTAssertTrue(result.actionItems.isEmpty)
    }

    func test_parse_summaryHeaderButNoActionItemsHeader_setsParseWarning() {
        let raw = """
        ## Summary
        We talked about the roadmap. Then the model trailed off without
        producing the action items section.
        """
        let result = SummaryParser.parse(raw)

        XCTAssertTrue(result.parseWarning,
            "## Summary without ## Action Items is malformed per the template.")
        XCTAssertTrue(result.summary.hasPrefix("We talked about"))
        XCTAssertTrue(result.actionItems.isEmpty)
    }
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter SummaryParserTests`

Expected: 4 tests passed.

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcSummarizeTests/SummaryParserTests.swift
git commit -m "$(cat <<'EOF'
test(summarize): cover malformed model output in SummaryParser

Two cases: no headers at all, and ## Summary present but
## Action Items missing. Both raise parseWarning while preserving
the raw text for display.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `SummaryParser` — actor and due parsing edge cases

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummaryParserTests.swift` (add 3 tests)

- [ ] **Step 1: Write the actor-less item test**

Append to `Tests/HarcSummarizeTests/SummaryParserTests.swift`:

```swift
    func test_parse_actionItemWithoutActor_keepsFullTextAndNilActor() {
        let raw = """
        ## Summary
        Standup.

        ## Action Items
        - [ ] follow up with the design review thread
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertNil(item.actor,
            "No leading 'Actor:' → actor should be nil.")
        XCTAssertEqual(item.text, "follow up with the design review thread")
        XCTAssertNil(item.due)
    }

    func test_parse_actionItemWithActorAndDue_extractsBoth() {
        let raw = """
        ## Summary
        Planning.

        ## Action Items
        - [ ] Jason: rewrite tiering page (next Friday)
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertEqual(item.actor, "Jason")
        XCTAssertEqual(item.text, "rewrite tiering page")
        XCTAssertEqual(item.due, "next Friday")
    }

    func test_parse_actionItemWithCommasInPrefix_doesNotMisidentifyActor() {
        // "Tuesday, Friday: ..." — colon in a phrase that isn't an
        // actor. The 3-word + no-comma heuristic should reject this.
        let raw = """
        ## Summary
        Time-boxed.

        ## Action Items
        - [ ] Tuesday, Friday: check in on rollout
        """
        let result = SummaryParser.parse(raw)

        XCTAssertEqual(result.actionItems.count, 1)
        let item = result.actionItems[0]
        XCTAssertNil(item.actor,
            "Comma-bearing prefix is not an actor name.")
        XCTAssertEqual(item.text, "Tuesday, Friday: check in on rollout")
    }
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter SummaryParserTests`

Expected: 7 tests passed (4 from prior tasks + 3 here).

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcSummarizeTests/SummaryParserTests.swift
git commit -m "$(cat <<'EOF'
test(summarize): cover actor + due edge cases in SummaryParser

Actor-less item, full actor + parenthetical due, and a comma-bearing
prefix that the heuristic must NOT mistake for an actor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `SummaryParser` — stray prose tolerance

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummaryParserTests.swift` (add 1 test)

- [ ] **Step 1: Write the stray-prose test**

Append to `Tests/HarcSummarizeTests/SummaryParserTests.swift`:

```swift
    func test_parse_strayProseBetweenItems_isIgnored() {
        // Gemma sometimes editorialises between the action items.
        // Lines that don't start with "- [ ]" / "- [x]" must be
        // skipped — the items list still contains exactly the two
        // checkbox lines.
        let raw = """
        ## Summary
        Reviewed the rollout plan.

        ## Action Items
        - [ ] Jason: confirm the rollout window
        Some commentary the model shouldn't have written.
        - [x] Amy: send the comms email
        """
        let result = SummaryParser.parse(raw)

        XCTAssertFalse(result.parseWarning)
        XCTAssertEqual(result.actionItems.count, 2,
            "Non-checkbox lines must not produce action items.")
        XCTAssertEqual(result.actionItems[0].actor, "Jason")
        XCTAssertEqual(result.actionItems[1].actor, "Amy")
        XCTAssertTrue(result.actionItems[1].done)
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter SummaryParserTests`

Expected: 8 tests passed.

- [ ] **Step 3: Commit**

```bash
git add Tests/HarcSummarizeTests/SummaryParserTests.swift
git commit -m "$(cat <<'EOF'
test(summarize): ignore stray prose between action items

Non-checkbox lines must not become action items. Locks the existing
parser behavior with an explicit test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Full Stage 1 verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire HarcSummarize test target**

Run: `swift test --filter HarcSummarizeTests 2>&1 | tail -30`

Expected: all tests pass — 3 from `SummaryOutputTests`, 4 from `SummaryPromptTests`, 8 from `SummaryParserTests`. Total: **15 tests passed**.

- [ ] **Step 2: Run the entire repo test suite to confirm nothing else regressed**

Run: `swift test 2>&1 | tail -10`

Expected: full suite green. Test count rises by 15 from the prior baseline of 261 to **276 tests passed**.

- [ ] **Step 3: Confirm Stage 1 spec coverage**

Open `docs/superpowers/specs/2026-04-22-local-summarization-design.md` §11 Stage 1 and verify each item lands:

- [x] New SwiftPM target `HarcSummarize` (deps: `HarcCore` only) — Task 1.
- [x] `SummaryOutput`, `ActionItem` value types — Task 2.
- [x] `SummaryPrompt` — template + `render(transcript:)` with head-truncation — Tasks 4–5 (`build` is the public surface; `renderBody` is the internal that does the truncation).
- [x] `SummaryParser.parse(_:)` covering all branches in §5.3 — Tasks 6–10.
- [x] §8.1 unit tests — `SummaryPromptTests` + `SummaryParserTests` — Tasks 4–10.

If any item isn't checked, return to the corresponding task.

---

## Self-Review Notes

Spec coverage scan (per the writing-plans skill checklist):

- **§2 in-scope (v1) — Stage 1 portions:** `HarcSummarize` target, `SummaryPrompt`, `SummaryParser`, `SummaryOutput`, `ActionItem`. All accounted for.
- **§5.1 template:** Verbatim in `SummaryPrompt.template` — Task 4.
- **§5.2 transcript rendering:** Speaker-prefix lines + head-truncation with `[Earlier in the meeting…]` prefix — Tasks 4–5.
- **§5.3 parser:** Header split, action-item line matching, actor + due parsing, malformed fallback — Tasks 6–10.
- **§8.1 tests:** Prompt snapshot (covered by render-content assertions in `SummaryPromptTests`), parser branches (6 — covered across Tasks 6–10).

Type consistency check: `ActionItem.text/actor/due/done` (Task 2), `SummaryParseResult.summary/actionItems/parseWarning` (Task 2), `SummaryOutput.summary/actionItems/model/generatedAt/elapsedMs/sourceWordCount/parseWarning` (Task 2) — all match the field names referenced in Tasks 6–10's tests.

No placeholder text in any task.
