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

// MARK: - Helpers

/// Simple async-safe counter for the load-count assertions.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
