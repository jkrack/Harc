import Testing
import Foundation
import HarcCore
@testable import HarcClient

@Suite("HarcClient end-to-end", .tags(.slow))
struct EndToEndTests {
    /// Copy the HarcSTTTests fixture into /tmp so the daemon test socket doesn't care about bundle paths.
    private func stageFixture() throws -> URL {
        let thisBundle = Bundle(for: Token.self)
        let build = (thisBundle.bundlePath as NSString).deletingLastPathComponent
        let candidates = [
            build + "/Harc_HarcSTTTests.bundle/Contents/Resources/Fixtures/short-speech.wav",
            build + "/HarcPackageTests.xctest/Contents/Resources/Fixtures/short-speech.wav",
            build + "/Harc_HarcSTTTests.bundle/Fixtures/short-speech.wav",
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
        let socketPath = "/tmp/harc-e2e-\(UUID().uuidString.prefix(8)).sock"
        let launcher = DaemonLauncher(socketPath: socketPath)
        _ = try await launcher.ensureRunning()

        let fixture = try stageFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let client = HarcSTTClient(socketPath: socketPath)

        // Wait for model load by polling status.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let s = try? await client.status(), s.modelLoaded { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let result = try await client.transcribe(audioPath: fixture.path, diarize: false)
        #expect(!result.text.isEmpty)
        #expect(result.text.lowercased().contains("test"), "got: \(result.text)")

        try? await client.shutdown()
        await launcher.stop()
    }
}

extension Tag {
    @Tag static var slow: Self
}
