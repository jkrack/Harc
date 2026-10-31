import Foundation
import Testing
@testable import HarcSummarize

@Suite("Summarizer operation ownership")
struct SummarizerConcurrencyTests {
    @Test func overlappingPreloadsShareOneLoad() async throws {
        let probe = ModelOperationProbe(holdLoad: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let first = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await probe.loads == 1 }
        let second = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await service.pendingOperationCount == 1 }
        #expect(await probe.loads == 1)
        await probe.release()
        try await first.value
        try await second.value
        #expect(await probe.loads == 1)
    }

    @Test func cancelledWaiterDoesNotLoadOrBlockSuccessor() async throws {
        let probe = ModelOperationProbe(holdLoad: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let first = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await probe.loads == 1 }
        let cancelled = Task { try await service.preload(modelID: "other", modelDirectory: .temporaryDirectory) }
        try await eventually { await service.pendingOperationCount == 1 }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Cancelled waiter succeeded") }
        catch is CancellationError { }
        let next = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await service.pendingOperationCount == 1 }
        await probe.release()
        try await first.value
        try await next.value
        #expect(await probe.loads == 1)
    }

    @Test func unloadInvalidatesSuspendedLoad() async throws {
        let probe = ModelOperationProbe(holdLoad: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let loading = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await probe.loads == 1 }
        await service.handleMemoryPressure()
        await probe.release()
        do { try await loading.value; Issue.record("Invalidated load succeeded") }
        catch is CancellationError { }
        #expect(await service.loadedModelID == nil)
        try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory)
        #expect(await probe.loads == 2)
    }

    @Test(arguments: [false, true])
    func failedLoadAfterInvalidationRemainsCancellation(memoryPressure: Bool) async throws {
        let probe = ModelOperationProbe(holdLoad: true, failFirstLoad: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let loading = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await probe.loads == 1 }
        if memoryPressure { await service.handleMemoryPressure() }
        else { loading.cancel() }
        await probe.release()
        do { try await loading.value; Issue.record("Invalidated load succeeded") }
        catch is CancellationError { }
        #expect(await service.loadedModelID == nil)
        try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory)
        #expect(await probe.loads == 2)
    }

    @Test func generationSerializesOtherEntryPoints() async throws {
        let probe = ModelOperationProbe(holdGeneration: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let answer = Task { try await service.answer(question: "q", contextMarkdown: "c", modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await probe.generations == 1 }
        let transform = Task { try await service.transform(text: "text", instruction: "edit", modelID: "m", modelDirectory: .temporaryDirectory) }
        try await eventually { await service.pendingOperationCount == 1 }
        #expect(await probe.generations == 1)
        await probe.release()
        _ = try await answer.value
        _ = try await transform.value
        #expect(await probe.generations == 2)
        #expect(await probe.loads == 1)
    }

    @Test(arguments: [false, true])
    func cancelledOrInvalidatedGenerationCannotReturnSummary(unload: Bool) async throws {
        let probe = ModelOperationProbe(holdGeneration: true)
        let service = SummarizerService(loader: { _ in try await probe.load() })
        defer { Task { await probe.release() } }
        let task = Task {
            try await service.summarize(transcript: .init(utterances: [.init(speaker: nil, text: "hello")]),
                modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 100)
        }
        try await eventually { await probe.generations == 1 }
        if unload { await service.unload() } else { task.cancel() }
        // The probe deliberately ignores cancellation while suspended.
        await probe.release()
        do { _ = try await task.value; Issue.record("Stale generation returned a summary") }
        catch is CancellationError { }
        _ = try await service.summarize(transcript: .init(utterances: [.init(speaker: nil, text: "next")]),
            modelID: "m", modelDirectory: .temporaryDirectory, budgetWords: 100)
        #expect(await probe.generations == 2)
    }

    @Test func sameModelAtDifferentDirectoryReloads() async throws {
        let probe = ModelOperationProbe()
        let service = SummarizerService(loader: { _ in try await probe.load() })
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory)
        try await service.preload(modelID: "m", modelDirectory: directory)
        #expect(await probe.loads == 2)
    }
}

private actor ModelOperationProbe: ContainerLike {
    var loads = 0
    var generations = 0
    private var holdLoad: Bool
    private var holdGeneration: Bool
    private let failFirstLoad: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(holdLoad: Bool = false, holdGeneration: Bool = false, failFirstLoad: Bool = false) {
        self.failFirstLoad = failFirstLoad
        self.holdLoad = holdLoad
        self.holdGeneration = holdGeneration
    }

    func load() async throws -> any ContainerLike {
        loads += 1
        if holdLoad { await withCheckedContinuation { continuation = $0 } }
        if failFirstLoad && loads == 1 { throw SummarizerError.loadFailed("delayed read failure") }
        return self
    }

    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String {
        generations += 1
        if holdGeneration { await withCheckedContinuation { continuation = $0 } }
        return "response"
    }

    func release() {
        holdLoad = false
        holdGeneration = false
        continuation?.resume()
        continuation = nil
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "SummarizerConcurrencyTests.timeout", code: 1) }
        try await Task.sleep(for: .milliseconds(1))
    }
}
