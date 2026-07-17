import Foundation
import Testing
@testable import HarcUI
import HarcClient

struct STTReadinessTests {
    @Test("model loaded → ready, regardless of prior verification")
    func loadedIsReady() {
        for verified in [true, false] {
            let r = STTReadiness.from(.init(
                socketExists: true, statusModelLoaded: true, modelVerifiedBefore: verified
            ))
            #expect(r == .ready)
            #expect(r.isReady)
        }
    }

    @Test("daemon up but model not loaded → preparing; first run mentions the download")
    func notLoadedIsPreparing() {
        let firstRun = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: false
        ))
        #expect(firstRun == .preparing(firstRun: true))
        #expect(!firstRun.isReady)
        #expect(firstRun.displayText.contains("460 MB"))

        let laterRun = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: true
        ))
        #expect(laterRun == .preparing(firstRun: false))
        #expect(!laterRun.displayText.contains("460 MB"))
    }

    @Test("daemon unreachable after prior verification → idle, not blocked")
    func idleAfterVerification() {
        let r = STTReadiness.from(.init(
            socketExists: false, statusModelLoaded: nil, modelVerifiedBefore: true
        ))
        #expect(r == .idle)
        #expect(r.isReady, "idle daemon relaunches on demand — capture isn't blocked")
    }

    @Test("daemon unreachable and never verified → waiting, blocked")
    func neverVerifiedIsBlocked() {
        let r = STTReadiness.from(.init(
            socketExists: false, statusModelLoaded: nil, modelVerifiedBefore: false
        ))
        #expect(r == .waitingForFirstModel)
        #expect(!r.isReady)
    }

    @Test("rich downloading state wins over the coarse bool and carries progress")
    func downloadingWinsWithProgress() {
        let r = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: false,
            modelState: .downloading, downloadProgress: 0.42
        ))
        #expect(r == .downloading(progress: 0.42))
        #expect(!r.isReady)
        #expect(r.progress == 0.42)
        #expect(r.displayText.contains("42%"))

        // No fraction from the daemon → indeterminate copy, no percent.
        let vague = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: false,
            modelState: .downloading
        ))
        #expect(vague == .downloading(progress: nil))
        #expect(vague.progress == nil)
        #expect(!vague.displayText.contains("%"))
    }

    @Test("rich failed state surfaces the daemon's message and blocks capture")
    func failedSurfacesMessage() {
        let r = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: true,
            modelState: .failed, errorMessage: "no network route to Hugging Face"
        ))
        #expect(r == .failed(message: "no network route to Hugging Face"))
        #expect(!r.isReady)
        #expect(r.displayText.contains("no network route"))

        // Missing message still produces something human.
        let bare = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: false, modelVerifiedBefore: true,
            modelState: .failed
        ))
        if case .failed(let message) = bare {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected .failed, got \(bare)")
        }
    }

    @Test("legacy daemon (nil modelState) falls back to the coarse mapping")
    func legacyDaemonFallback() {
        let r = STTReadiness.from(.init(
            socketExists: true, statusModelLoaded: true, modelVerifiedBefore: true,
            modelState: nil
        ))
        #expect(r == .ready)
    }

    @Test("disk probe finds a parakeet directory and ignores others")
    func diskProbe() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("STTProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(!STTModelDiskProbe.modelPresent(under: base))

        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("silero-vad"), withIntermediateDirectories: true
        )
        #expect(!STTModelDiskProbe.modelPresent(under: base))

        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("parakeet-tdt-0.6b-v3"), withIntermediateDirectories: true
        )
        #expect(STTModelDiskProbe.modelPresent(under: base))
    }
}

struct DictationHumanErrorTests {
    @Test("model_not_loaded reads as a download in progress, not a fault")
    func modelNotLoaded() {
        let error = ClientError.transcribeFailed(
            code: "model_not_loaded",
            message: "Model not loaded — call loadModels() first"
        )
        let message = DictationController.humanMessage(for: error)
        #expect(message == "Speech model is still downloading — try again shortly")
    }

    @Test("timeouts and unreachable daemons read as transient")
    func transientErrors() {
        #expect(DictationController.humanMessage(for: ClientError.timeout(seconds: 20))
            .contains("try again"))
        #expect(DictationController.humanMessage(for: ClientError.daemonNotReachable("x"))
            .contains("restarts"))
    }

    @Test("other errors pass through their own description")
    func passthrough() {
        let error = ClientError.transcribeFailed(code: "bad_audio", message: "unreadable file")
        #expect(DictationController.humanMessage(for: error).contains("bad_audio"))
    }
}

struct DestinationFolderCreationTests {
    @Test("createDirectoryIfMissing creates a missing directory and is idempotent")
    func createsAndIdempotent() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcDestTests-\(UUID().uuidString)/nested/dir").path
        defer {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent
            )
        }

        HarcPreferences.createDirectoryIfMissing(atPath: path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Second call is a no-op, not an error.
        HarcPreferences.createDirectoryIfMissing(atPath: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@MainActor
struct WelcomeSetupSuggestionTests {
    @Test("suggested summarizer fits RAM and never exceeds the quality tier")
    func suggestionRespectsRAM() {
        // Tiny RAM → still suggests something (the default standard tier).
        let small = WelcomeSetupModel.suggestedSummarizer(ramGB: 4)
        #expect(small != nil)
        #expect(small?.tier == .standard || small?.tier == .quality)

        // Plenty of RAM → best of standard/quality, never pro/max.
        let big = WelcomeSetupModel.suggestedSummarizer(ramGB: 128)
        #expect(big != nil)
        #expect(big?.tier == .standard || big?.tier == .quality)
    }
}
