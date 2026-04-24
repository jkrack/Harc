# Summarization Stage 2 — SummarizerService Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire mlx-swift-lm into the `HarcSummarize` target by shipping a `SummarizerService` actor that loads Gemma 4 from a local directory, runs summarization against a `PromptTranscript`, and returns a `SummaryParseResult`. Expose lazy load + nil-out unload + memory-pressure-driven unload. Ship a gated integration test that exercises the real MLX path end-to-end.

**Architecture:** `SummarizerService` is an actor that owns an optional `ContainerLike` (protocol) + the currently-loaded model id. Production `ContainerLike` wraps `MLXLMCommon.ModelContainer`; tests use a mock. `summarize(...)` builds the Gemma-bound prompt via the Stage 1 `SummaryPrompt`, runs generation through `container.generate` (an `AsyncStream<Generation>`), aggregates chunks, and hands the raw text to the Stage 1 `SummaryParser`. Cancellation is structured-concurrency native — cancelling the caller's task terminates the stream. Memory pressure unload is driven by an internal `DispatchSource.makeMemoryPressureSource` that calls `unload()` on warning/critical signals.

**Tech Stack:** Swift 6 actors, `mlx-swift-lm` 3.31.3 (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`), `swift-transformers` (`Tokenizers`), `swift-huggingface` (`HuggingFace`), XCTest. All new deps are already on the branch (commit `097166e`).

**Spec reference:** `docs/superpowers/specs/2026-04-22-local-summarization-design.md` §3 (deps), §4.3 (service), §4.4 (memory pressure), §5 (prompt/parser, already shipped in Stage 1), §6.2 (budget), §11 Stage 2.

---

## File Structure

**Files created in this plan:**

| Path | Purpose |
|---|---|
| `Sources/HarcSummarize/SummarizerService.swift` | The actor + `SummarizerError` enum + internal memory-pressure wiring. |
| `Sources/HarcSummarize/ContainerLike.swift` | Protocol that abstracts generation behind a testable seam; concrete MLX-backed impl lives here too. |
| `Sources/HarcSummarize/SummaryPromptBudget.swift` | Pure `SummaryPrompt.budgetWords(contextTokens:)` helper implementing §6.2. |
| `Tests/HarcSummarizeTests/SummarizerServiceTests.swift` | Actor state-machine tests + summarize integration tests using a mock `ContainerLike`. |
| `Tests/HarcSummarizeTests/SummaryPromptBudgetTests.swift` | Pure-function tests for the budget math. |

**Files modified:**

| Path | Change |
|---|---|
| `Tests/HarcSummarizeTests/MLXLoadVerifyTests.swift` | Add a second test that exercises `SummarizerService.summarize` end-to-end (in addition to the existing raw-MLX load test). Stays gated by `HARC_INTEGRATION_TESTS=1`. |

**Package.swift:** **no changes** — the MLX / swift-transformers / swift-huggingface deps already landed with commit `097166e` when we promoted the spike branch.

---

## Task 1: Sanity-check the promoted spike branch

**Files:** none (verification only)

- [ ] **Step 1: Confirm branch state**

Run: `git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 log --oneline -3`

Expected output should show `097166e` (the promoted spike commit), `42a3164` (spec refresh), and older commits.

- [ ] **Step 2: Confirm the MLX deps still resolve and compile**

Run: `cd /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 && swift build --target HarcSummarize 2>&1 | tail -5`

Expected: `Build complete!` with no errors.

- [ ] **Step 3: Confirm non-integration tests still pass**

Run: `swift test 2>&1 | grep -E "passed|failed" | tail -10`

Expected: all Stage 1 HarcSummarize tests pass; the integration `MLXLoadVerifyTests` is skipped because `HARC_INTEGRATION_TESTS` is unset.

No commit for this task — it's just verification that the branch is sound before we start adding code.

---

## Task 2: `SummarizerError` enum + `ContainerLike` protocol + service skeleton

**Files:**
- Create: `Sources/HarcSummarize/ContainerLike.swift`
- Create: `Sources/HarcSummarize/SummarizerService.swift`
- Create: `Tests/HarcSummarizeTests/SummarizerServiceTests.swift`

- [ ] **Step 1: Write the first failing test**

Create `Tests/HarcSummarizeTests/SummarizerServiceTests.swift`:

```swift
import XCTest
@testable import HarcSummarize

final class SummarizerServiceTests: XCTestCase {

    func test_newService_reportsNoLoadedModel() async {
        let service = SummarizerService(loader: { _ in
            throw SummarizerError.loadFailed("not called")
        })
        let loaded = await service.loadedModelID
        XCTAssertNil(loaded,
            "A freshly-constructed service has no model loaded.")
    }

    func test_unload_clearsLoadedModelID() async {
        // Construct with a stub loader that returns a no-op container
        // whose generate-spy just records the call.
        let service = SummarizerService(loader: StubContainer.loader(id: "test-model"))
        // Prime the service by calling summarize once; the stub returns
        // a well-formed two-section response. /tmp is a real directory
        // so the existence check inside getOrLoad passes and the loader
        // actually fires.
        _ = try? await service.summarize(
            transcript: PromptTranscript(utterances: [
                .init(speaker: nil, text: "hello")
            ]),
            modelID: "test-model",
            modelDirectory: URL(fileURLWithPath: "/tmp"),
            budgetWords: 100
        )
        var loaded = await service.loadedModelID
        XCTAssertEqual(loaded, "test-model")

        await service.unload()
        loaded = await service.loadedModelID
        XCTAssertNil(loaded,
            "unload() must clear the loaded model id.")
    }
}

// MARK: - Test stub

/// Minimal `ContainerLike` used to exercise state transitions without
/// touching real MLX. Records generate calls and returns a canned
/// two-section Gemma-formatted response.
final class StubContainer: ContainerLike, @unchecked Sendable {
    let id: String
    private(set) var generateCalls = 0

    init(id: String) { self.id = id }

    static func loader(id: String) -> @Sendable (URL) async throws -> any ContainerLike {
        { _ in StubContainer(id: id) }
    }

    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
        generateCalls += 1
        return """
        ## Summary
        Stubbed summary from \(id).

        ## Action Items
        _None identified._
        """
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SummarizerServiceTests 2>&1 | tail -10`

Expected: build error — `SummarizerService`, `SummarizerError`, and `ContainerLike` undefined.

- [ ] **Step 3: Create `ContainerLike` protocol**

Create `Sources/HarcSummarize/ContainerLike.swift`:

```swift
import Foundation

/// Abstraction over the mlx-swift-lm `ModelContainer` used by
/// `SummarizerService`. Production code uses `MLXModelContainer` (see
/// below) which wraps `MLXLMCommon.ModelContainer`. Unit tests pass a
/// stub implementation so we can cover state-machine behaviour without
/// compiling a Metal library or loading multi-GB weights.
public protocol ContainerLike: Sendable {
    /// Render the prompt through the model's chat template, generate
    /// up to `maxTokens` tokens, and return the aggregated string.
    /// `systemPrompt` is optional — when non-nil it's rendered as a
    /// `{role: "system"}` message ahead of the user turn.
    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String
}
```

- [ ] **Step 4: Create `SummarizerService` skeleton**

Create `Sources/HarcSummarize/SummarizerService.swift`:

```swift
import Foundation

/// Recoverable errors surfaced by `SummarizerService`. Non-recoverable
/// bugs (contract violations) trap as usual.
public enum SummarizerError: Error, LocalizedError {
    case loadFailed(String)
    case generationFailed(String)
    case modelDirectoryMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            return "Couldn't load the summarization model: \(reason)"
        case .generationFailed(let reason):
            return "Summarization generation failed: \(reason)"
        case .modelDirectoryMissing(let url):
            return "Model directory not present at \(url.path). Download the model in Settings first."
        }
    }
}

/// Actor that owns a lazily-loaded LLM container and serves
/// summarization requests. Single-tenant by design — one in-flight
/// summarize at a time — because the underlying Gemma model has a
/// multi-GB resident footprint and concurrent generation blows RAM.
/// The caller (Stage 3's queue) enforces serial scheduling.
///
/// Thread model: actor. All state mutation is serialized. Callers
/// interact via `await`. Cancellation is structured-concurrency
/// native: cancel the calling `Task` and the generation terminates
/// at the next stream iteration.
public actor SummarizerService {

    /// Factory signature for loading a `ContainerLike` from a model
    /// directory on disk. Injected at init so tests can substitute a
    /// stub that doesn't require Metal.
    public typealias Loader = @Sendable (URL) async throws -> any ContainerLike

    private let loader: Loader
    private(set) public var loadedModelID: String?
    private var container: (any ContainerLike)?

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    /// Drop the resident model so MLX can reclaim GPU/ANE memory.
    /// Implemented by nil-ing the container — `mlx-swift-lm` 3.x has
    /// no explicit unload method. Next `summarize(...)` pays the load
    /// cost again.
    public func unload() {
        container = nil
        loadedModelID = nil
    }

    /// Placeholder for Task 3. Full implementation lands in Task 5.
    public func summarize(
        transcript: PromptTranscript,
        modelID: String,
        modelDirectory: URL,
        budgetWords: Int
    ) async throws -> SummaryParseResult {
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        // Minimal body for Task 2: just prove the container is reachable.
        // Task 5 replaces this with the real prompt / parse pipeline.
        let raw = try await cont.generate(
            promptBody: "(stage-2 task-2 placeholder)",
            systemPrompt: nil,
            maxTokens: 16
        )
        return SummaryParser.parse(raw)
    }

    /// Load or reuse the container for `modelID`. Reloads when the id
    /// changes. Validates that the directory exists before calling the
    /// loader — the loader itself is free to assume the directory is
    /// present.
    private func getOrLoad(modelID: String, directory: URL) async throws -> any ContainerLike {
        if let container, loadedModelID == modelID {
            return container
        }
        // Different id (or first call) — drop any stale container
        // before loading so a mid-load failure doesn't leave the
        // service in a half-initialised state.
        container = nil
        loadedModelID = nil

        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SummarizerError.modelDirectoryMissing(directory)
        }

        let newContainer: any ContainerLike
        do {
            newContainer = try await loader(directory)
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.loadFailed(error.localizedDescription)
        }
        container = newContainer
        loadedModelID = modelID
        return newContainer
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter SummarizerServiceTests 2>&1 | tail -10`

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Sources/HarcSummarize/ContainerLike.swift \
  Sources/HarcSummarize/SummarizerService.swift \
  Tests/HarcSummarizeTests/SummarizerServiceTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
feat(summarize): SummarizerService skeleton with unload + lazy load

Actor that owns a ContainerLike and serves summarize() calls. In this
task the actor only validates directory existence, delegates to an
injected loader, and proves the container round-trip via SummaryParser.
Full prompt-building + generation-integration lands in Task 5.

The ContainerLike protocol abstracts real MLXLMCommon.ModelContainer
behind a one-method interface so unit tests can exercise the state
machine without compiling Metal or loading multi-GB weights.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Container reuse (load / reuse / reload)

**Files:**
- Modify: `Tests/HarcSummarizeTests/SummarizerServiceTests.swift` (add 3 tests)

- [ ] **Step 1: Write the reuse test**

Append inside the existing `final class SummarizerServiceTests: XCTestCase`:

```swift
    func test_summarize_reusesContainerForSameModelID() async throws {
        let created = Counter()
        let service = SummarizerService(loader: { _ in
            await created.increment()
            return StubContainer(id: "same")
        })
        let modelDir = URL(fileURLWithPath: "/tmp")
        let transcript = PromptTranscript(utterances: [
            .init(speaker: nil, text: "hello")
        ])

        _ = try await service.summarize(
            transcript: transcript,
            modelID: "same",
            modelDirectory: modelDir,
            budgetWords: 100
        )
        _ = try await service.summarize(
            transcript: transcript,
            modelID: "same",
            modelDirectory: modelDir,
            budgetWords: 100
        )

        let count = await created.value
        XCTAssertEqual(count, 1,
            "Loader should be called exactly once for repeated same-id requests.")
    }

    func test_summarize_reloadsWhenModelIDChanges() async throws {
        let created = Counter()
        let service = SummarizerService(loader: { _ in
            await created.increment()
            return StubContainer(id: "any")
        })
        let modelDir = URL(fileURLWithPath: "/tmp")
        let transcript = PromptTranscript(utterances: [
            .init(speaker: nil, text: "hello")
        ])

        _ = try await service.summarize(
            transcript: transcript,
            modelID: "first",
            modelDirectory: modelDir,
            budgetWords: 100
        )
        _ = try await service.summarize(
            transcript: transcript,
            modelID: "second",
            modelDirectory: modelDir,
            budgetWords: 100
        )

        let count = await created.value
        XCTAssertEqual(count, 2,
            "Switching model id must trigger a reload.")
    }

    func test_summarize_throwsWhenDirectoryMissing() async {
        let service = SummarizerService(loader: { _ in
            XCTFail("Loader must not be invoked when the directory is missing.")
            return StubContainer(id: "never")
        })
        let missing = URL(fileURLWithPath: "/tmp/harc-summarizer-test-definitely-missing-\(UUID().uuidString)")

        do {
            _ = try await service.summarize(
                transcript: PromptTranscript(utterances: []),
                modelID: "any",
                modelDirectory: missing,
                budgetWords: 100
            )
            XCTFail("Expected modelDirectoryMissing to throw.")
        } catch SummarizerError.modelDirectoryMissing(let url) {
            XCTAssertEqual(url, missing)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
```

Also add this helper actor at the bottom of the file (outside the test class, after `StubContainer`):

```swift
/// Simple async-safe counter for the load-count assertions.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `swift test --filter SummarizerServiceTests 2>&1 | tail -15`

Expected: 5 tests pass (2 from Task 2 + 3 new). The state-machine logic in `getOrLoad` already handles these cases; these tests pin the behavior.

- [ ] **Step 3: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Tests/HarcSummarizeTests/SummarizerServiceTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
test(summarize): cover container reuse + reload + missing-directory

Three tests pinning the SummarizerService state machine: loader fires
once for repeated same-id requests, fires again when the model id
changes, and the missing-directory case throws without ever invoking
the loader.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `SummaryPrompt.budgetWords` helper

**Files:**
- Create: `Sources/HarcSummarize/SummaryPromptBudget.swift`
- Create: `Tests/HarcSummarizeTests/SummaryPromptBudgetTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HarcSummarizeTests/SummaryPromptBudgetTests.swift`:

```swift
import XCTest
@testable import HarcSummarize

final class SummaryPromptBudgetTests: XCTestCase {

    func test_budgetWords_forGemma4E2B_returnsPositiveWordCount() {
        // Spec §6.2 formula against Gemma 4 E2B's 32k context:
        //   budgetTokens = min(32000, 32000) - 1200 - 1024  = 29776
        //   budgetWords  = 29776 / 1.3                      = 22904
        let budget = SummaryPrompt.budgetWords(contextTokens: 32_000)
        XCTAssertGreaterThan(budget, 20_000,
            "32k context should leave well over 20k words after overhead.")
        XCTAssertLessThan(budget, 25_000,
            "The overhead reservations should cap the budget well under raw tokens/1.3.")
    }

    func test_budgetWords_clamps32kCap() {
        // If a model reports >32k context (e.g. 128k), we still cap at
        // 32k for the prompt budget — beyond that the prompt becomes
        // unwieldy and summarization quality degrades in practice.
        let budget32k = SummaryPrompt.budgetWords(contextTokens: 32_000)
        let budget128k = SummaryPrompt.budgetWords(contextTokens: 128_000)
        XCTAssertEqual(budget32k, budget128k,
            "Models with larger context are still clamped at the 32k prompt cap.")
    }

    func test_budgetWords_forTinyContext_returnsNonNegative() {
        // Pathologically small context (shouldn't happen in prod, but
        // the function shouldn't underflow).
        let budget = SummaryPrompt.budgetWords(contextTokens: 1_000)
        XCTAssertGreaterThanOrEqual(budget, 0,
            "A tiny context window must not underflow the budget.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SummaryPromptBudgetTests 2>&1 | tail -10`

Expected: build error — `SummaryPrompt.budgetWords` undefined.

- [ ] **Step 3: Implement the helper**

Create `Sources/HarcSummarize/SummaryPromptBudget.swift`:

```swift
import Foundation

extension SummaryPrompt {

    /// Prompt-overhead reservation in tokens — the template body plus
    /// chat-template wrapping that Gemma adds at tokenization time.
    /// Conservative; measured empirically on the Gemma 4 E2B chat
    /// template. Bump this if the template ever grows meaningfully.
    static let promptOverheadTokens = 1_200

    /// Reserved generation budget. Fixed at 1024 per spec §6.3 — a
    /// 6-sentence summary + 10 action items fits comfortably.
    static let maxOutputTokens = 1_024

    /// Hard ceiling on how much of the model's context we'll actually
    /// use for the prompt body. Beyond 32k the summary quality tends
    /// to degrade regardless of how much context the model supports.
    static let maxPromptTokens = 32_000

    /// Approximate tokens-per-word for English. Conservative — real
    /// English averages ~1.3–1.5, so using 1.3 leans toward slightly
    /// over-reserving budget.
    static let tokensPerEnglishWord: Double = 1.3

    /// Translate the model's reported context window into an English
    /// word budget for `SummaryPrompt.build`. Implements spec §6.2.
    public static func budgetWords(contextTokens: Int) -> Int {
        let cappedContext = min(contextTokens, maxPromptTokens)
        let budgetTokens = cappedContext - promptOverheadTokens - maxOutputTokens
        guard budgetTokens > 0 else { return 0 }
        let budgetWords = Double(budgetTokens) / tokensPerEnglishWord
        return Int(budgetWords.rounded(.down))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SummaryPromptBudgetTests 2>&1 | tail -10`

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Sources/HarcSummarize/SummaryPromptBudget.swift \
  Tests/HarcSummarizeTests/SummaryPromptBudgetTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
feat(summarize): SummaryPrompt.budgetWords helper

Pure function implementing spec §6.2: translate a model's context
window (in tokens) into the word budget that SummaryPrompt.build
should target, accounting for template overhead + reserved output
tokens. Clamps at 32k prompt tokens regardless of how much the
model claims to support.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `SummarizerService.summarize` — generation + parser integration

**Files:**
- Modify: `Sources/HarcSummarize/SummarizerService.swift` (replace the Task-2 placeholder body)
- Modify: `Tests/HarcSummarizeTests/SummarizerServiceTests.swift` (add 2 tests + enhance stub)

- [ ] **Step 1: Enhance `StubContainer` to echo the prompt for assertions**

Edit `Tests/HarcSummarizeTests/SummarizerServiceTests.swift`. Replace the `StubContainer` class body with:

```swift
final class StubContainer: ContainerLike, @unchecked Sendable {
    let id: String
    private(set) var generateCalls = 0
    private(set) var lastPromptBody: String?
    private(set) var lastSystemPrompt: String?
    private(set) var lastMaxTokens: Int?
    /// Caller can override the canned response for a specific test.
    var response: String

    init(id: String,
         response: String = """
        ## Summary
        Stubbed summary.

        ## Action Items
        _None identified._
        """
    ) {
        self.id = id
        self.response = response
    }

    static func loader(id: String,
                       response: String? = nil) -> @Sendable (URL) async throws -> any ContainerLike {
        { _ in
            if let response {
                return StubContainer(id: id, response: response)
            }
            return StubContainer(id: id)
        }
    }

    func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
        generateCalls += 1
        lastPromptBody = promptBody
        lastSystemPrompt = systemPrompt
        lastMaxTokens = maxTokens
        return response
    }
}
```

Note: because `SummarizerService.loader` produces a new stub per load call, the tests that assert on the stub's recorded state need to capture the stub instance. Use a reference-holding closure:

Replace the existing same-id reuse and reload tests' loader expressions to capture the stub when created. Add near the top of the test file (inside the class) a helper:

```swift
    /// Spy loader that records every produced container so tests can
    /// assert on recorded state post-summarize.
    func spyLoader(id: String,
                   response: String? = nil) -> (loader: SummarizerService.Loader,
                                                 containers: () async -> [StubContainer]) {
        let box = Box<[StubContainer]>(initial: [])
        let loader: SummarizerService.Loader = { _ in
            let stub = StubContainer(id: id, response: response ?? """
            ## Summary
            Stubbed summary.

            ## Action Items
            _None identified._
            """)
            await box.append(stub)
            return stub
        }
        return (loader, { await box.snapshot() })
    }
```

And add this helper actor at the bottom of the file (after `Counter`):

```swift
/// Minimal async-safe box so the spy loader can record produced
/// containers across multiple invocations.
actor Box<T> {
    private var storage: T
    init(initial: T) { self.storage = initial }
    func snapshot() -> T { storage }
    func assign(_ value: T) { storage = value }
}

extension Box where T == [StubContainer] {
    func append(_ item: StubContainer) { storage.append(item) }
}
```

- [ ] **Step 2: Write the happy-path summarize test**

Add to `SummarizerServiceTests`:

```swift
    func test_summarize_happyPath_returnsParsedResult() async throws {
        let canned = """
        ## Summary
        The team reviewed the rollout plan and agreed on timing.

        ## Action Items
        - [ ] Jason: confirm the rollout window (Friday)
        - [x] Amy: send the comms email
        """
        let (loader, containers) = spyLoader(id: "m", response: canned)
        let service = SummarizerService(loader: loader)

        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Let's lock rollout for Friday."),
            .init(speaker: "Amy", text: "I'll send the comms email."),
        ])

        let result = try await service.summarize(
            transcript: transcript,
            modelID: "m",
            modelDirectory: URL(fileURLWithPath: "/tmp"),
            budgetWords: 1_000
        )

        XCTAssertFalse(result.parseWarning,
            "Well-formed stubbed output should not raise the warning.")
        XCTAssertEqual(result.actionItems.count, 2)
        XCTAssertEqual(result.actionItems[0].actor, "Jason")
        XCTAssertTrue(result.actionItems[1].done)

        let produced = await containers()
        XCTAssertEqual(produced.count, 1, "One container produced.")
        let stub = produced[0]
        XCTAssertEqual(stub.generateCalls, 1)
        XCTAssertEqual(stub.lastMaxTokens, SummaryPrompt.maxOutputTokens,
            "Service must pass the canonical maxOutputTokens to the container.")
        XCTAssertTrue(stub.lastPromptBody?.contains("Jason: Let's lock rollout for Friday.") ?? false,
            "Prompt body must contain the speaker-labeled transcript lines.")
        XCTAssertTrue(stub.lastPromptBody?.contains("## Summary") ?? false,
            "Prompt body must include the Stage 1 template.")
    }

    func test_summarize_passesSystemPromptFromService() async throws {
        let (loader, containers) = spyLoader(id: "m")
        let service = SummarizerService(loader: loader)

        _ = try await service.summarize(
            transcript: PromptTranscript(utterances: [
                .init(speaker: nil, text: "hi")
            ]),
            modelID: "m",
            modelDirectory: URL(fileURLWithPath: "/tmp"),
            budgetWords: 100
        )

        let produced = await containers()
        XCTAssertEqual(produced.count, 1)
        XCTAssertNil(produced[0].lastSystemPrompt,
            "v1 deliberately passes no system prompt — the template carries the instructions.")
    }
```

- [ ] **Step 3: Replace the Task-2 placeholder body of `summarize`**

In `Sources/HarcSummarize/SummarizerService.swift`, replace the whole `summarize(transcript:modelID:modelDirectory:budgetWords:)` body:

```swift
    public func summarize(
        transcript: PromptTranscript,
        modelID: String,
        modelDirectory: URL,
        budgetWords: Int
    ) async throws -> SummaryParseResult {
        let cont = try await getOrLoad(modelID: modelID, directory: modelDirectory)
        let promptBody = SummaryPrompt.build(
            transcript: transcript,
            budgetWords: budgetWords
        )

        let raw: String
        do {
            // The template already carries the instructions — no
            // separate system prompt in v1. See the §5.1 template.
            raw = try await cont.generate(
                promptBody: promptBody,
                systemPrompt: nil,
                maxTokens: SummaryPrompt.maxOutputTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.generationFailed(error.localizedDescription)
        }

        return SummaryParser.parse(raw)
    }
```

- [ ] **Step 4: Run all HarcSummarize tests**

Run: `swift test --filter HarcSummarizeTests 2>&1 | tail -15`

Expected: all Stage 1 tests + 5 SummarizerServiceTests + 3 SummaryPromptBudgetTests pass. Total new in this stage so far: 8.

- [ ] **Step 5: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Sources/HarcSummarize/SummarizerService.swift \
  Tests/HarcSummarizeTests/SummarizerServiceTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
feat(summarize): SummarizerService.summarize wires prompt → container → parser

Replaces the Task-2 placeholder body with the real pipeline:
- SummaryPrompt.build renders the §5.1 template + transcript body
- container.generate runs the model with the canonical maxOutputTokens
- SummaryParser.parse turns the raw response into SummaryParseResult

CancellationError propagates unchanged so callers can abort via
structured concurrency; other container errors surface as
SummarizerError.generationFailed.

Two new tests (spy loader + StubContainer prompt recording): happy-path
parse assertions + the deliberate absence of a system prompt in v1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Memory-pressure-driven unload

**Files:**
- Modify: `Sources/HarcSummarize/SummarizerService.swift` (add memory-pressure wiring)
- Modify: `Tests/HarcSummarizeTests/SummarizerServiceTests.swift` (add 1 test)

- [ ] **Step 1: Write the failing test**

Append to `SummarizerServiceTests`:

```swift
    func test_handleMemoryPressure_callsUnload() async {
        let (loader, _) = spyLoader(id: "m")
        let service = SummarizerService(loader: loader)

        _ = try? await service.summarize(
            transcript: PromptTranscript(utterances: [
                .init(speaker: nil, text: "hello")
            ]),
            modelID: "m",
            modelDirectory: URL(fileURLWithPath: "/tmp"),
            budgetWords: 100
        )
        var loaded = await service.loadedModelID
        XCTAssertEqual(loaded, "m")

        // Simulate a memory-pressure signal (the real DispatchSource
        // can't be triggered synthetically in unit tests; we call the
        // actor's handler directly to exercise the unload path).
        await service.handleMemoryPressure()

        loaded = await service.loadedModelID
        XCTAssertNil(loaded,
            "Memory-pressure handler must unload the model.")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SummarizerServiceTests 2>&1 | tail -10`

Expected: build error — `handleMemoryPressure` undefined.

- [ ] **Step 3: Add the memory-pressure handler + source wiring**

Edit `Sources/HarcSummarize/SummarizerService.swift`. Add these to the class body, after the `init`:

```swift
    /// Testing seam: the memory-pressure handler, callable directly by
    /// tests. In production it's invoked by the `DispatchSource` set up
    /// in `startObservingMemoryPressure()`.
    public func handleMemoryPressure() {
        unload()
    }

    /// Begin observing OS-level memory pressure warnings and nil-out
    /// the resident container on warning/critical events. Safe to call
    /// multiple times; only the first call installs the source. Caller
    /// owns the returned handle — retain it for the lifetime of the
    /// service; dropping it cancels observation.
    ///
    /// Not called from `init` because actor isolation combined with
    /// `DispatchSource` event handlers would require a Task hop on
    /// every invocation. The caller (AppDelegate in Stage 3) calls
    /// this explicitly after construction.
    public nonisolated func startObservingMemoryPressure() -> MemoryPressureObservation {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }
        source.resume()
        return MemoryPressureObservation(source: source)
    }

    /// Handle returned from `startObservingMemoryPressure`. Drops the
    /// underlying DispatchSource when deallocated, which stops event
    /// delivery.
    public final class MemoryPressureObservation: @unchecked Sendable {
        private let source: DispatchSourceMemoryPressure
        init(source: DispatchSourceMemoryPressure) { self.source = source }
        deinit { source.cancel() }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SummarizerServiceTests 2>&1 | tail -10`

Expected: 9 tests pass (8 prior + 1 new).

- [ ] **Step 5: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Sources/HarcSummarize/SummarizerService.swift \
  Tests/HarcSummarizeTests/SummarizerServiceTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
feat(summarize): memory-pressure-driven unload via DispatchSource

Adds handleMemoryPressure() (testable seam, calls unload) and
startObservingMemoryPressure() (production wiring, returns an
observation handle the caller retains).

Uses DispatchSource.makeMemoryPressureSource(.warning | .critical) so
the OS tells us when to drop the ~3.6 GB Gemma resident set rather
than us guessing at idle timeouts. Event handler hops to the actor
via Task so actor isolation is preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Production MLX-backed `ContainerLike`

**Files:**
- Modify: `Sources/HarcSummarize/ContainerLike.swift` (add production impl + a default loader factory)

- [ ] **Step 1: Add the production wrapper**

Edit `Sources/HarcSummarize/ContainerLike.swift`. Add after the protocol definition:

```swift
import MLXLLM
import MLXLMCommon
import MLXHuggingFace

/// Production `ContainerLike` backed by `MLXLMCommon.ModelContainer`.
/// Thin wrapper: builds `UserInput` from the prompt body (+ optional
/// system message), prepares, generates, and aggregates `Generation`
/// chunks into one string.
public struct MLXModelContainer: ContainerLike {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func generate(
        promptBody: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
        // mlx-swift-lm 3.x takes raw message dicts here, not a
        // Chat.Message array. Each dict has "role" + "content".
        var messages: [[String: any Sendable]] = []
        if let systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": promptBody])

        let userInput = UserInput(messages: messages)
        let lmInput = try await container.prepare(input: userInput)

        var params = GenerateParameters()
        params.maxTokens = maxTokens

        let stream = try await container.generate(input: lmInput, parameters: params)

        var result = ""
        for await generation in stream {
            switch generation {
            case .chunk(let fragment):
                result += fragment
            case .info:
                break   // final stats; not used by the parser
            case .toolCall:
                break   // not a tool-use model
            }
        }
        return result
    }
}

extension SummarizerService {

    /// Default production loader. Resolves a directory URL to an
    /// `MLXModelContainer` via `LLMModelFactory.shared.loadContainer`
    /// using the HuggingFace tokenizer macro for tokenization. Inject
    /// this at `SummarizerService.init(loader:)` in production code.
    ///
    /// The `#huggingFaceTokenizerLoader()` macro expands at compile
    /// time to a TokenizerLoader that reads the model directory's
    /// `tokenizer.json` + `tokenizer_config.json`.
    public static let defaultLoader: Loader = { @Sendable directory in
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        return MLXModelContainer(container: container)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build --target HarcSummarize 2>&1 | tail -5`

Expected: `Build complete!` with no errors. No unit tests — the wrapper is covered by the integration test added in Task 8 and can only be meaningfully exercised with real Metal + real weights.

- [ ] **Step 3: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Sources/HarcSummarize/ContainerLike.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
feat(summarize): MLX-backed ContainerLike + SummarizerService.defaultLoader

Production ContainerLike wraps MLXLMCommon.ModelContainer: builds
UserInput from [{role, content}] dicts (the 3.x API shape), prepares,
generates via AsyncStream<Generation>, and aggregates .chunk payloads
into the raw string the parser consumes.

SummarizerService.defaultLoader is the production factory: calls
LLMModelFactory.shared.loadContainer(from:using:) with the
#huggingFaceTokenizerLoader macro, wraps in MLXModelContainer, and
hands back a ContainerLike. Inject this at AppDelegate wiring time
(Stage 3). Unit tests use their own stub loader.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Integration test via `SummarizerService`

**Files:**
- Modify: `Tests/HarcSummarizeTests/MLXLoadVerifyTests.swift` (add a second test)

- [ ] **Step 1: Add the `SummarizerService`-exercising integration test**

Append to `Tests/HarcSummarizeTests/MLXLoadVerifyTests.swift` inside the existing `final class MLXLoadVerifyTests: XCTestCase`:

```swift
    func test_summarizerService_endToEnd_producesParsedSummary() async throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let modelDir = appSupport
            .appendingPathComponent("Harc", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("gemma-4-e2b-it-4bit", isDirectory: true)

        try XCTSkipUnless(
            fm.fileExists(atPath: modelDir.path),
            "Gemma 4 E2B not installed at \(modelDir.path). Download it via Harc Settings → Models first."
        )

        let service = SummarizerService(loader: SummarizerService.defaultLoader)
        let transcript = PromptTranscript(utterances: [
            .init(speaker: "Jason", text: "Let's lock rollout for Friday."),
            .init(speaker: "Amy", text: "I'll send the comms email on Thursday."),
        ])

        let result = try await service.summarize(
            transcript: transcript,
            modelID: "gemma-4-e2b-it-4bit",
            modelDirectory: modelDir,
            budgetWords: SummaryPrompt.budgetWords(contextTokens: 32_000)
        )

        XCTAssertFalse(
            result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Summary must be non-empty."
        )
        // We can't pin specific action items (the model's output varies
        // across runs), but we can insist on SOMETHING structured —
        // either a non-empty list or an explicit "_None identified._"
        // that the parser turned into an empty array. Both are fine.
        XCTAssertFalse(result.parseWarning,
            "Well-installed model + correct prompt should not raise parseWarning; raw=\(result.summary)")
        print("SummarizerService.summarize result — summary (\(result.summary.count) chars), \(result.actionItems.count) action items")
    }
```

- [ ] **Step 2: Build to confirm everything still compiles**

Run: `swift build 2>&1 | tail -5`

Expected: `Build complete!` with no errors. The actual run of this test requires Xcode (see the metallib note in the spec) and is gated by `HARC_INTEGRATION_TESTS=1`; the unit-test run below should skip it.

- [ ] **Step 3: Run the non-integration test suite**

Run: `swift test 2>&1 | grep -E "passed|failed" | tail -5`

Expected: all tests pass; the two tests in `MLXLoadVerifyTests` skip (no env var set).

- [ ] **Step 4: Commit**

```bash
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 add \
  Tests/HarcSummarizeTests/MLXLoadVerifyTests.swift
git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 commit -m "$(cat <<'EOF'
test(summarize): end-to-end integration test via SummarizerService

Companion to the raw-MLX load test already on this branch. Constructs
a real SummarizerService with the production defaultLoader, runs a
summary of a trivially-short transcript, and asserts the output is
non-empty + parses without a warning. Gated by HARC_INTEGRATION_TESTS=1
+ presence of the downloaded Gemma 4 E2B model.

Must be run from an Xcode scheme (xcodebuild test) — swift test from
CLI hits the mlx-swift metallib-bundling limitation and can't execute
Metal kernels.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Full Stage 2 verification

**Files:** none (verification only)

- [ ] **Step 1: Full build from a clean slate**

Run: `swift build 2>&1 | tail -10`

Expected: `Build complete!` with no warnings introduced by this stage's code.

- [ ] **Step 2: Full test suite (non-integration)**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ test|Test run with" | tail -10`

Expected: every XCTest count reported shows `0 failures`. The Swift Testing side count is unchanged from Stage 1 (261). The XCTest count rises from 72 (end of Stage 1) by 12 — 5 `SummarizerServiceTests` + 3 `SummaryPromptBudgetTests` + the `Test run` line itself doesn't change, each per-suite run reports its own number; the grand total ends at **84 XCTest + 261 Swift Testing = 345 tests passed, 0 failures.** The two `MLXLoadVerifyTests` skip (no env var).

- [ ] **Step 3: Confirm commit history is clean**

Run: `git -C /Users/jlane/GitHub/Harc/.worktrees/summarization-stage-2 log --oneline d6480f0..HEAD`

Expected to see, in order (most recent first):
- Task 8 commit (integration test)
- Task 7 commit (MLX-backed ContainerLike)
- Task 6 commit (memory pressure)
- Task 5 commit (summarize pipeline)
- Task 4 commit (budgetWords helper)
- Task 3 commit (container reuse tests)
- Task 2 commit (service skeleton)
- `097166e` (the promoted spike — deps + MLXLoadVerifyTests)
- older commits (spec + Stage 1 merge).

Each message should be prefixed `feat(summarize):` or `test(summarize):` and include the `Co-Authored-By` trailer.

- [ ] **Step 4: Confirm Stage 2 spec coverage**

Open `docs/superpowers/specs/2026-04-22-local-summarization-design.md` §11 Stage 2 and verify each bullet has a corresponding task in this plan:

- [x] `mlx-swift-lm` + `swift-huggingface` + `swift-transformers` packages — landed in `097166e` (promoted spike).
- [x] `HarcSummarize` gains `MLXLLM` / `MLXLMCommon` / `MLXHuggingFace` / `HuggingFace` / `Tokenizers` deps — landed in `097166e`.
- [x] `SummarizerService` actor with `summarize(...)` and `unload()` — Tasks 2 + 5.
- [x] Lazy load from `~/Library/Application Support/Harc/Models/<id>/` via `LLMModelFactory.shared.loadContainer(from:using:)` — Task 7 (`defaultLoader`).
- [x] Memory pressure unload hook — Task 6.
- [x] Manual integration test gated by `HARC_INTEGRATION_TESTS=1` — `MLXLoadVerifyTests` landed in `097166e`, Task 8 adds the `SummarizerService`-exercising companion.

If any item is unchecked, return to the matching task.

---

## Self-Review Notes

Spec coverage walked above. Type-consistency check:

- `SummarizerService.loader` typealias: `@Sendable (URL) async throws -> any ContainerLike` — used in Tasks 2, 3, 5, 7.
- `ContainerLike.generate(promptBody:systemPrompt:maxTokens:)` — signature fixed in Task 2, consumed in Tasks 5, 7, 8.
- `SummaryPrompt.maxOutputTokens`, `SummaryPrompt.budgetWords(contextTokens:)` — declared in Task 4, consumed in Tasks 5, 8.
- `SummarizerError` cases: `.loadFailed`, `.generationFailed`, `.modelDirectoryMissing` — all introduced in Task 2, thrown in Tasks 2 (directory) + 5 (generation). No orphan cases.
- `SummaryParseResult` from Stage 1 is the return type of `summarize` — consumed but not modified.

No placeholders. No "TBD" / "implement later" / "handle edge cases" bodies. Every step with a code change shows the complete code. Every commit command includes the exact message.

One implementation caveat documented inline: the integration test in Task 8 (and the existing `MLXLoadVerifyTests`) cannot run under `swift test` from the CLI because `mlx-swift`'s `default.metallib` is only compiled by Xcode build phases. The test is correct and will run from an Xcode scheme or `xcodebuild test`. Stage 3 will add the Xcode scheme plumbing to make this a one-command invocation; for now the tests exist in the codebase, are `XCTSkipUnless`-gated, and stay out of the default `swift test` flow.
