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
        var lastVAD: Bool?
        var result: TranscribeResult = TranscribeResult(
            text: "fake", words: [], speakers: [], processingMs: 1
        )

        func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult {
            lastPath = audioPath
            lastVAD = vad
            return result
        }

        var isLoaded: Bool { true }
        var stateOverride: Transcriber.ModelState = .ready
        func setModelState(_ s: Transcriber.ModelState) { stateOverride = s }
        var modelState: Transcriber.ModelState { stateOverride }
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
            #expect(s.modelState == .ready)
            #expect(s.downloadProgress == nil)
            #expect(s.errorMessage == nil)
        } else {
            Issue.record("expected .status response, got: \(resp)")
        }
    }

    @Test("status reports downloading model state with progress over IPC")
    func statusReportsDownloadState() async throws {
        let fake = FakeTranscriber()
        await fake.setModelState(.downloading(progress: 0.42))
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.status)
        if case .status(let s) = resp {
            #expect(s.modelState == .downloading)
            #expect(s.downloadProgress == 0.42)
        } else {
            Issue.record("expected .status, got: \(resp)")
        }
    }

    @Test("status reports failed model state with message")
    func statusReportsFailureState() async throws {
        let fake = FakeTranscriber()
        await fake.setModelState(.failed(message: "offline"))
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.status)
        if case .status(let s) = resp {
            #expect(s.modelState == .failed)
            #expect(s.errorMessage == "offline")
        } else {
            Issue.record("expected .status, got: \(resp)")
        }
    }

    @Test("DaemonStatus decodes legacy payloads without model-state fields")
    func daemonStatusBackwardCompatibleDecoding() throws {
        let legacyJSON = #"{"version":"0.4.1","modelLoaded":true,"uptimeSeconds":12}"#
        let decoded = try JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        #expect(decoded.modelLoaded == true)
        #expect(decoded.modelState == nil)
        #expect(decoded.downloadProgress == nil)
        #expect(decoded.errorMessage == nil)
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

    @Test("transcribe request threads req.vad to TranscribeService")
    func transcribePassesVAD() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        _ = await handler.handle(.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", vad: false)))
        #expect(await fake.lastVAD == false)

        _ = await handler.handle(.transcribe(TranscribeRequest(audioPath: "/tmp/y.wav")))
        #expect(await fake.lastVAD == true)
    }

    // Fake diarizer for tests below.
    actor FakeDiarizer: DiarizeService {
        var diarizeCalls: [String] = []
        var diarizeWithEmbeddingsCalls: [String] = []

        var segmentsResult: [SpeakerSegment] = []
        var diarizationResult: Diarizer.DiarizationOutput = Diarizer.DiarizationOutput(
            segments: [],
            speakers: []
        )

        func setSegmentsResult(_ v: [SpeakerSegment]) { segmentsResult = v }
        func setDiarizationResult(_ v: Diarizer.DiarizationOutput) { diarizationResult = v }

        func diarize(audioPath: String) async throws -> [SpeakerSegment] {
            diarizeCalls.append(audioPath)
            return segmentsResult
        }

        func diarizeWithEmbeddings(audioPath: String) async throws -> Diarizer.DiarizationOutput {
            diarizeWithEmbeddingsCalls.append(audioPath)
            return diarizationResult
        }

        var isLoaded: Bool { true }
    }

    @Test("transcribe with diarize=false skips the diarizer entirely")
    func transcribeSkipsDiarizerWhenFlagFalse() async throws {
        let fake = FakeTranscriber()
        let fakeDi = FakeDiarizer()
        await fakeDi.setSegmentsResult([SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)])
        let handler = RequestHandler(
            transcriber: fake, diarizer: fakeDi, version: "0.1.0", startedAt: Date()
        )
        let req = IPCRequest.transcribe(TranscribeRequest(audioPath: "/tmp/x.wav", diarize: false))
        let resp = await handler.handle(req)
        if case .result(let r) = resp {
            #expect(r.speakers.isEmpty, "expected diarizer skipped, but got speakers: \(r.speakers)")
        } else {
            Issue.record("expected .result, got: \(resp)")
        }
        #expect(await fakeDi.diarizeCalls.isEmpty)
        #expect(await fakeDi.diarizeWithEmbeddingsCalls.isEmpty)
    }

    @Test("transcribe with diarization returns segments and embeddings together")
    func transcribeReturnsDiarizationEmbeddings() async throws {
        let fake = FakeTranscriber()
        let fakeDi = FakeDiarizer()
        let embedding = SpeakerEmbeddingRow(
            speakerIndex: 0,
            vector: [Float](repeating: 0.0625, count: 256),
            totalMs: 2_000,
            segmentCount: 1
        )
        await fakeDi.setDiarizationResult(Diarizer.DiarizationOutput(
            segments: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 2_000)],
            speakers: [embedding]
        ))
        let handler = RequestHandler(
            transcriber: fake,
            diarizer: fakeDi,
            version: "0.1.0",
            startedAt: Date()
        )

        let response = await handler.handle(.transcribe(
            TranscribeRequest(audioPath: "/tmp/d.wav", diarize: true)
        ))

        guard case .result(let result) = response else {
            Issue.record("expected .result, got: \(response)")
            return
        }
        #expect(result.speakers.count == 1)
        #expect(result.speakerEmbeddings == [embedding])
        #expect(await fakeDi.diarizeWithEmbeddingsCalls == ["/tmp/d.wav"])
        #expect(await fakeDi.diarizeCalls.isEmpty)
    }

    @Test("diarize request returns .diarization with embeddings")
    func diarizeRequestReturnsEmbeddings() async throws {
        let fake = FakeTranscriber()
        let fakeDi = FakeDiarizer()
        await fakeDi.setDiarizationResult(Diarizer.DiarizationOutput(
            segments: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 2000)],
            speakers: [SpeakerEmbeddingRow(
                speakerIndex: 0,
                vector: [Float](repeating: 0.0625, count: 256),
                totalMs: 2000,
                segmentCount: 1
            )]
        ))
        let handler = RequestHandler(
            transcriber: fake, diarizer: fakeDi, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.diarize(DiarizeRequest(audioPath: "/tmp/d.wav")))
        if case .diarization(let d) = resp {
            #expect(d.segments.count == 1)
            #expect(d.speakers.count == 1)
            #expect(d.speakers[0].vector.count == 256)
        } else {
            Issue.record("expected .diarization, got: \(resp)")
        }
        #expect(await fakeDi.diarizeWithEmbeddingsCalls == ["/tmp/d.wav"])
    }

    @Test("diarize request without a diarizer returns .error")
    func diarizeWithoutDiarizerErrors() async throws {
        let fake = FakeTranscriber()
        let handler = RequestHandler(
            transcriber: fake, diarizer: nil, version: "0.1.0", startedAt: Date()
        )
        let resp = await handler.handle(.diarize(DiarizeRequest(audioPath: "/tmp/d.wav")))
        if case .error(let e) = resp {
            #expect(e.code == "diarizer_unavailable")
        } else {
            Issue.record("expected .error, got: \(resp)")
        }
    }
}
