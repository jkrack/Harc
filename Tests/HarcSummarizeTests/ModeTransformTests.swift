import XCTest
@testable import HarcSummarize

final class ModeTransformPromptTests: XCTestCase {

    func test_build_embedsInstructionAndTranscript() {
        let body = ModeTransformPrompt.build(
            instruction: "Rewrite as an email.",
            transcript: "hey can we move the sync to three"
        )
        XCTAssertTrue(body.contains("Rewrite as an email."))
        XCTAssertTrue(body.contains("hey can we move the sync to three"))
        XCTAssertTrue(body.contains("<<<"), "Transcript must be fenced so instructions can't be injected by dictated text.")
    }

    func test_systemPrompt_demandsBareOutput() {
        XCTAssertTrue(ModeTransformPrompt.systemPrompt.contains("Output only the transformed text"))
    }
}

final class SummarizerServiceTransformTests: XCTestCase {

    func test_transform_returnsTrimmedGeneration_withDefaultSystemPrompt() async throws {
        let service = SummarizerService(
            loader: StubContainer.loader(id: "m1", response: "  Polished text.\n")
        )
        let result = try await service.transform(
            text: "raw dictated words",
            instruction: "Clean this up.",
            modelID: "m1",
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(result, "Polished text.")
    }

    func test_transform_passesModeSystemPromptOverride() async throws {
        let stub = StubContainer(id: "m1", response: "x")
        let service = SummarizerService(loader: { _ in stub })
        _ = try await service.transform(
            text: "words",
            instruction: "Do it.",
            systemPrompt: "CUSTOM SYSTEM",
            modelID: "m1",
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(stub.lastSystemPrompt, "CUSTOM SYSTEM")
        XCTAssertEqual(stub.lastMaxTokens, ModeTransformPrompt.maxOutputTokens)
        XCTAssertTrue(stub.lastPromptBody?.contains("Do it.") == true)
    }

    func test_transform_missingModelDirectoryThrows() async {
        let service = SummarizerService(loader: StubContainer.loader(id: "m1"))
        do {
            _ = try await service.transform(
                text: "words",
                instruction: "Do it.",
                modelID: "m1",
                modelDirectory: URL(fileURLWithPath: "/definitely/not/a/real/dir")
            )
            XCTFail("Expected modelDirectoryMissing")
        } catch let error as SummarizerError {
            guard case .modelDirectoryMissing = error else {
                return XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_transform_sharesResidentContainerWithSummarize() async throws {
        let (loader, containers) = spyLoader(id: "m1")
        let service = SummarizerService(loader: loader)
        _ = try await service.summarize(
            transcript: PromptTranscript(utterances: [.init(speaker: nil, text: "hello")]),
            modelID: "m1",
            modelDirectory: URL(fileURLWithPath: "/tmp"),
            budgetWords: 100
        )
        _ = try await service.transform(
            text: "words",
            instruction: "Do it.",
            modelID: "m1",
            modelDirectory: URL(fileURLWithPath: "/tmp")
        )
        let loadedContainers = await containers()
        XCTAssertEqual(loadedContainers.count, 1,
            "transform must reuse the container summarize loaded — no second load.")
    }

    /// Same spy-loader helper as `SummarizerServiceTests` (kept local to this
    /// file to avoid cross-file test coupling).
    private func spyLoader(id: String) -> (loader: SummarizerService.Loader,
                                           containers: () async -> [StubContainer]) {
        let box = Box<[StubContainer]>(initial: [])
        let loader: SummarizerService.Loader = { _ in
            let stub = StubContainer(id: id)
            await box.append(stub)
            return stub
        }
        return (loader, { await box.snapshot() })
    }
}
