import Foundation
import CryptoKit
import Testing
@testable import HarcModels
@testable import HarcSummarize

/// Cross-module synthetic harness only: proves snapshot lifetime and exact
/// fake-loader input, not production bundle provenance or semantic inference.
@Suite struct EvidenceSnapshotServiceTests {
    @Test func verifiedCopyReplacesOrdinaryPreloadAndSurvivesThroughGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("synthetic verified weights".utf8)
        let filename = "model.safetensors"
        try bytes.write(to: source.appendingPathComponent(filename))
        let file = SyntheticEvidenceSnapshot.File(name: filename, bytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let probe = SnapshotLoaderProbe(expectedBytes: bytes, filename: filename)
        let service = SummarizerService(loader: { directory in try await probe.load(directory) })
        // A previous ordinary preload must not be reused for the new snapshot.
        try await service.preload(modelID: "fixture", modelDirectory: source)
        try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { snapshot in
            try await service.preload(modelID: "fixture", modelDirectory: snapshot)
            #expect(await probe.paths.count == 2)
            #expect(await probe.paths.last == snapshot.standardizedFileURL)
            let output = try await service.generateEvidence(promptBody: "synthetic source only", modelID: "fixture",
                modelDirectory: snapshot, budget: EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20))
            #expect(output == "{\"decision\":\"abstain\"}")
            #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(filename).path))
            await service.unload()
            await #expect(throws: EvidenceGenerationError.modelNotResident) {
                try await service.generateEvidence(promptBody: "synthetic", modelID: "fixture",
                    modelDirectory: snapshot, budget: EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent(filename)) == bytes)
    }

    @Test func badManifestNeverInvokesLoader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: source.appendingPathComponent("model.safetensors"))
        let probe = SnapshotLoaderProbe(expectedBytes: Data("x".utf8), filename: "model.safetensors")
        let service = SummarizerService(loader: { directory in try await probe.load(directory) })
        let file = SyntheticEvidenceSnapshot.File(name: "model.safetensors", bytes: 1, sha256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) {
            try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { snapshot in
                try await service.preload(modelID: "fixture", modelDirectory: snapshot)
            }
        }
        #expect(await probe.paths.isEmpty)
    }
}

private actor SnapshotLoaderProbe {
    let expectedBytes: Data
    let filename: String
    var paths: [URL] = []
    init(expectedBytes: Data, filename: String) { self.expectedBytes = expectedBytes; self.filename = filename }
    func load(_ directory: URL) throws -> any ContainerLike {
        let observed = try Data(contentsOf: directory.appendingPathComponent(filename))
        guard observed == expectedBytes else { throw EvidenceGenerationError.unsupported }
        paths.append(directory.standardizedFileURL)
        return SnapshotFakeContainer(directory: directory, expectedBytes: expectedBytes, filename: filename)
    }
}
private struct SnapshotFakeContainer: ContainerLike {
    let directory: URL
    let expectedBytes: Data
    let filename: String
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String { "" }
    func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String {
        guard try Data(contentsOf: directory.appendingPathComponent(filename)) == expectedBytes else {
            throw EvidenceGenerationError.unsupported
        }
        return "{\"decision\":\"abstain\"}"
    }
}
