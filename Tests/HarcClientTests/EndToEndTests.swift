import Testing
import Foundation
import AVFoundation
import HarcCore
@testable import HarcClient

@Suite(
    "HarcClient end-to-end",
    .tags(.slow),
    .enabled(
        if: ProcessInfo.processInfo.environment["HARC_INTEGRATION_TESTS"] == "1",
        "Set HARC_INTEGRATION_TESTS=1 to run the real-model client integration test."
    )
)
struct EndToEndTests {
    /// Copy the HarcSTTTests fixture into /tmp so the daemon test socket doesn't care about bundle paths.
    private func stageFixture() throws -> URL {
        let thisBundle = Bundle(for: Token.self)
        let build = (thisBundle.bundlePath as NSString).deletingLastPathComponent
        let candidates = [
            build + "/Harc_HarcSTTTests.bundle/Contents/Resources/Fixtures/short-speech.wav",
            build + "/HarcPackageTests.xctest/Contents/Resources/Fixtures/short-speech.wav",
            build + "/Harc_HarcSTTTests.bundle/Fixtures/short-speech.wav",
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("HarcSTTTests/Fixtures/short-speech.wav").path,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            let dst = URL(fileURLWithPath: "/tmp/harc-e2e-\(UUID().uuidString.prefix(8)).wav")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: c), to: dst)
            return dst
        }
        throw ClientError.chunkerFailed("fixture not found in any candidate path")
    }

    private final class Token {}

    @Test("launch daemon + transcribe fixture end-to-end")
    func transcribeFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["HARC_CLIENT_E2E_ENGINE"] ?? "v2"
        try #require(["v2", "unified"].contains(engine), "Unknown diagnostic engine")
        let diarizationOption = environment["HARC_CLIENT_E2E_DIARIZE"] ?? "0"
        try #require(["0", "1"].contains(diarizationOption), "Unknown diagnostic diarization option")
        let requiresDiarization = diarizationOption == "1"
        let root = URL(fileURLWithPath: "/tmp/harc-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("daemon.sock").path
        let output = environment["HARC_CLIENT_E2E_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let launcher = DaemonLauncher(socketPath: socketPath, asrEngine: engine,
            logURL: (output ?? root).appendingPathComponent("daemon.log"))
        let fixture = try stageFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let audio = environment["HARC_CLIENT_E2E_AUDIO"].map { URL(fileURLWithPath: $0) } ?? fixture
        let client = HarcSTTClient(socketPath: socketPath)
        do {
            _ = try await launcher.ensureRunning()
            let deadline = Date().addingTimeInterval(180)
            var loaded = false
            while Date() < deadline {
                if let s = try? await client.status(), s.modelLoaded { loaded = true; break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try #require(loaded, "Daemon model readiness deadline expired")
            let result: TranscribeResult
            if requiresDiarization {
                result = try await client.transcribeRequiringDiarization(
                    audioPath: audio.path, vad: true, diarizer: client)
                #expect(!result.speakers.isEmpty)
                #expect(!result.speakerEmbeddings.isEmpty)
                #expect(result.overlapRanges != nil)
                #expect(result.speakerEmbeddings.allSatisfy {
                    !$0.vector.isEmpty && $0.vector.allSatisfy(\.isFinite)
                        && $0.totalMs > 0 && $0.segmentCount > 0
                })
            } else {
                result = try await client.transcribe(audioPath: audio.path, diarize: false)
            }
            #expect(!result.text.isEmpty)
            #expect(!result.words.isEmpty)
            let file = try AVAudioFile(forReading: audio)
            let durationMs = Double(file.length) / file.processingFormat.sampleRate * 1000
            #expect(result.words.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs && Double($0.endMs) <= durationMs + 1000 })
            #expect(zip(result.words, result.words.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
            if environment["HARC_CLIENT_E2E_AUDIO"] == nil {
                #expect(result.text.lowercased().contains("test"), "got: \(result.text)")
            }
            if let output {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result).write(to: output.appendingPathComponent("result.json"), options: .atomic)
            }
            await #expect(throws: (any Error).self) {
                try await client.transcribe(audioPath: root.appendingPathComponent("missing.wav").path, diarize: false)
            }
            let recovered = try await client.transcribe(audioPath: fixture.path, diarize: false)
            #expect(recovered.text.lowercased().contains("test"))
            #expect(!recovered.words.isEmpty)
            try await client.shutdown()
            await launcher.stop()
        } catch {
            await launcher.shutdownDaemon(client: client)
            throw error
        }
    }
}

extension Tag {
    @Tag static var slow: Self
}
