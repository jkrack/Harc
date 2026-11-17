import Foundation
import Testing
@testable import HarcSummarize

@Suite struct EvidenceGenerationTests {
    @Test func tokenBoundaries() throws {
        let budget = try EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20)
        try budget.validate(promptTokens: 80)
        #expect(throws: EvidenceGenerationError.contextExceeded) { try budget.validate(promptTokens: 81) }
        #expect(throws: EvidenceGenerationError.contextExceeded) { try budget.validate(promptTokens: 0) }
        #expect(throws: EvidenceGenerationError.invalidBudget) { try EvidenceGenerationBudget(contextLimit: 100, outputReserve: 100) }
    }
    @Test func requiresExactlyOneNormalFinalCompletion() throws {
        var collector = EvidenceGenerationCollector()
        try collector.append("{\"decision\":\"abstain\"}")
        #expect(throws: EvidenceGenerationError.invalidCompletion) { try collector.finish() }
        #expect(throws: EvidenceGenerationError.invalidCompletion) { try collector.complete(normally: false) }
        try collector.complete(normally: true)
        #expect(try collector.finish() == "{\"decision\":\"abstain\"}")
        #expect(throws: EvidenceGenerationError.invalidCompletion) { try collector.complete(normally: true) }
        #expect(throws: EvidenceGenerationError.invalidCompletion) { try collector.append(" ") }
    }
    @Test func outputByteBound() throws {
        var collector = EvidenceGenerationCollector()
        try collector.append(String(repeating: "a", count: 4096))
        #expect(throws: EvidenceGenerationError.outputExceeded) { try collector.append("é") }
    }
    @Test func neverLoadsMissingResidentModel() async throws {
        let service = SummarizerService(loader: { _ in Issue.record("Must not load"); return EvidenceProbe() })
        do {
            _ = try await service.generateEvidence(promptBody: "synthetic", modelID: "m", modelDirectory: .temporaryDirectory,
                budget: EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20))
            Issue.record("Missing resident model accepted")
        } catch EvidenceGenerationError.modelNotResident { }
    }
    @Test func serializedAndInvalidatedByUnload() async throws {
        let probe = EvidenceProbe()
        let service = SummarizerService(loader: { _ in probe })
        try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory)
        let generation = Task { try await service.generateEvidence(promptBody: "synthetic", modelID: "m",
            modelDirectory: .temporaryDirectory, budget: EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20)) }
        for _ in 0..<1000 { if await probe.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await probe.started)
        let next = Task { try await service.preload(modelID: "m", modelDirectory: .temporaryDirectory) }
        for _ in 0..<1000 { if await service.pendingOperationCount == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await service.pendingOperationCount == 1)
        await service.unload()
        await probe.release()
        do { _ = try await generation.value; Issue.record("Invalidated generation returned") } catch is CancellationError { }
        do { try await next.value; Issue.record("Invalidated waiter returned") } catch is CancellationError { }
    }
}

private actor EvidenceProbe: ContainerLike {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String { "" }
    func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return "{\"decision\":\"abstain\"}"
    }
    func release() { continuation?.resume(); continuation = nil }
}
