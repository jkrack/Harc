import XCTest
@testable import HarcSummarize

final class SummarizerServiceTests: XCTestCase {

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

    func test_answer_usesConversationPromptAndSystemInstruction() async throws {
        let (loader, containers) = spyLoader(id: "m", response: "Neal wants staged migration.")
        let service = SummarizerService(loader: loader)

        let answer = try await service.answer(
            question: "What does Neal think about Atlas?",
            contextMarkdown: "# Context: Atlas\n\nNeal wants staged migration.",
            modelID: "m",
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(answer, "Neal wants staged migration.")
        let produced = await containers()
        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].lastSystemPrompt, ConversationPrompt.systemPrompt)
        XCTAssertEqual(produced[0].lastMaxTokens, ConversationPrompt.maxOutputTokens)
        XCTAssertTrue(produced[0].lastPromptBody?.contains("What does Neal think about Atlas?") ?? false)
        XCTAssertTrue(produced[0].lastPromptBody?.contains("Neal wants staged migration.") ?? false)
    }

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
}

// MARK: - Test stub

/// Minimal `ContainerLike` used to exercise state transitions without
/// touching real MLX. Records generate calls and returns a canned
/// two-section Gemma-formatted response.
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

// MARK: - Helpers

/// Simple async-safe counter for the load-count assertions.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

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
