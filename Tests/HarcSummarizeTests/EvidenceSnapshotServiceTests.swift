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

    @Test(arguments: [false, true])
    func suspendedGenerationKeepsSnapshotUntilSuccessOrFailure(fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("synthetic held generation".utf8)
        let filename = "model.safetensors"
        try bytes.write(to: source.appendingPathComponent(filename))
        let file = SyntheticEvidenceSnapshot.File(name: filename, bytes: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let gate = SnapshotGenerationGate()
        let service = SummarizerService(loader: { directory in
            HeldSnapshotContainer(directory: directory, filename: filename, bytes: bytes, gate: gate, fails: fails)
        })
        let run = Task {
            try await SyntheticEvidenceSnapshot.withSnapshot(source: source, scratch: scratch, files: [file]) { snapshot in
                try await service.preload(modelID: "fixture", modelDirectory: snapshot)
                do {
                    _ = try await service.generateEvidence(promptBody: "synthetic", modelID: "fixture",
                        modelDirectory: snapshot, budget: EvidenceGenerationBudget(contextLimit: 100, outputReserve: 20))
                    await service.unload()
                } catch {
                    // Snapshot ownership must outlast the resident container,
                    // not merely a successful generation response.
                    await service.unload()
                    throw error
                }
            }
        }
        for _ in 0..<1000 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.started)
        let staged = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
        #expect(staged.count == 1)
        if let directory = staged.first {
            #expect(try Data(contentsOf: directory.appendingPathComponent(filename)) == bytes)
        }
        await gate.release()
        do { try await run.value; #expect(!fails) }
        catch EvidenceGenerationError.outputExceeded { #expect(fails) }
        #expect(await service.loadedModelID == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
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
        #expect(await probe.invocations == 0)
    }
}

private actor SnapshotLoaderProbe {
    let expectedBytes: Data
    let filename: String
    var paths: [URL] = []
    var invocations = 0
    init(expectedBytes: Data, filename: String) { self.expectedBytes = expectedBytes; self.filename = filename }
    func load(_ directory: URL) throws -> any ContainerLike {
        invocations += 1
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

private actor SnapshotGenerationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct HeldSnapshotContainer: ContainerLike {
    let directory: URL
    let filename: String
    let bytes: Data
    let gate: SnapshotGenerationGate
    let fails: Bool
    func generate(promptBody: String, systemPrompt: String?, maxTokens: Int,
                  onStats: (@Sendable (GenerationStats) -> Void)?) async throws -> String { "" }
    func generateEvidence(promptBody: String, budget: EvidenceGenerationBudget) async throws -> String {
        await gate.wait()
        guard try Data(contentsOf: directory.appendingPathComponent(filename)) == bytes else {
            throw EvidenceGenerationError.unsupported
        }
        if fails { throw EvidenceGenerationError.outputExceeded }
        return #"{"decision":"abstain"}"#
    }
}
