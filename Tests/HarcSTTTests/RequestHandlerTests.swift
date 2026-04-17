import Testing
import Foundation
import HarcCore
@testable import HarcSTT

@Suite("RequestHandler")
struct RequestHandlerTests {
    // Test double that pretends to be the real Transcriber so we can unit-test
    // the handler without loading a real CoreML model.
    actor FakeTranscriber: TranscribeService {
        var loadCalled = false
        var lastPath: String?
        var result: TranscribeResult = TranscribeResult(
            text: "fake", words: [], speakers: [], processingMs: 1
        )

        func transcribe(audioPath: String) async throws -> TranscribeResult {
            lastPath = audioPath
            return result
        }

        var isLoaded: Bool { true }
    }

    @Test("status request returns current DaemonStatus")
    func statusRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake,
            diarizer: nil,
            version: "9.9.9",
            startedAt: Date().addingTimeInterval(-10)
        )
        let resp = await handler.handle(.status)
        if case .status(let s) = resp {
            #expect(s.version == "9.9.9")
            #expect(s.modelLoaded == true)
            #expect(s.uptimeSeconds >= 9)
        } else {
            Issue.record("expected .status response, got: \(resp)")
        }
    }

    @Test("shutdown request returns status response")
    func shutdownRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.shutdown)
        if case .status = resp {
            // ok
        } else {
            Issue.record("expected .status response for shutdown, got: \(resp)")
        }
    }

    @Test("transcribe request delegates to the transcriber and returns .result")
    func transcribeRequest() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/whatever.wav"))
        let resp = await handler.handle(req)
        if case .result(let r) = resp {
            #expect(r.text == "fake")
        } else {
            Issue.record("expected .result response, got: \(resp)")
        }
        await #expect(fake.lastPath == "/tmp/whatever.wav")
    }

    @Test("transcribe with diarize=true but no diarizer available still succeeds (empty speakers)")
    func transcribeDiarizeWithoutDiarizer() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", diarize: true))
        let resp = await handler.handle(req)
        if case .result(let r) = resp {
            #expect(r.speakers.isEmpty)
        } else {
            Issue.record("expected .result, got: \(resp)")
        }
    }
}
