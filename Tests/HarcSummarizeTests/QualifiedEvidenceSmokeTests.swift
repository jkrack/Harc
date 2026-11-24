import XCTest
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
@testable import HarcSummarize

/// Explicit opt-in, synthetic prompt only. Never reads owner recordings or
/// downloads a model. No prompt/response text is printed to logs.
final class QualifiedEvidenceSmokeTests: XCTestCase {
    func testInstalledE2BScopedOfflineSyntheticSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HARC_QUALIFIED_EVIDENCE_SMOKE"] == "1", "Opt-in installed-model smoke only")
        let source = try XCTUnwrap(environment["HARC_QUALIFIED_EVIDENCE_SOURCE"])
        let scratch = try XCTUnwrap(environment["HARC_QUALIFIED_EVIDENCE_SCRATCH"])
        let metrics = EvidenceSmokeMetrics()
        let service = SummarizerService(loader: { directory in
            let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
            return MLXModelContainer(container: container) { prompt, generated, reason in
                metrics.record(prompt: prompt, generated: generated, reason: reason)
            }
        })
        let started = Date()
        let result = try await service.generateQualifiedEvidence(
            promptBody: "This is a synthetic parser smoke test. Return exactly this JSON and nothing else: {\"decision\":\"abstain\"}",
            modelID: "gemma-4-e2b-it-4bit", installedDirectory: URL(fileURLWithPath: source),
            scratchDirectory: URL(fileURLWithPath: scratch))
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String]
        XCTAssertTrue(object == ["decision": "abstain"], "Unexpected smoke response schema")
        let observed = metrics.values
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.2, "stop")
        XCTAssertGreaterThan(observed.first?.0 ?? 0, 0)
        XCTAssertGreaterThan(observed.first?.1 ?? 0, 0)
        let resident = await service.loadedModelID
        XCTAssertNil(resident)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch).isEmpty)
        print("QUALIFIED_EVIDENCE_SMOKE model=gemma-4-e2b-it-4bit promptTokens=\(observed.first?.0 ?? -1) generatedTokens=\(observed.first?.1 ?? -1) stop=\(observed.first?.2 ?? "missing") elapsedSeconds=\(Date().timeIntervalSince(started)) peakMLXBytes=\(Memory.peakMemory) activeMLXBytes=\(Memory.activeMemory) cleaned=true")
    }
}

private final class EvidenceSmokeMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int, String)] = []
    var values: [(Int, Int, String)] { lock.withLock { storage } }
    func record(prompt: Int, generated: Int, reason: String) {
        lock.withLock { storage.append((prompt, generated, reason)) }
    }
}
