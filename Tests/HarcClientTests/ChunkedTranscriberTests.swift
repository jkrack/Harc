import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
@testable import HarcClient

/// Fake client that returns canned results based on call count.
/// Defined at file scope so both test suites can use it.
actor FakeClient: TranscribingClient {
    var calls: [(path: String, diarize: Bool, vad: Bool)] = []
    var results: [TranscribeResult]
    init(results: [TranscribeResult]) { self.results = results }
    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        calls.append((audioPath, diarize, vad))
        if results.isEmpty {
            return TranscribeResult(text: "", words: [], speakers: [], processingMs: 0)
        }
        return results.removeFirst()
    }
}

@Suite("ChunkedTranscriber")
struct ChunkedTranscriberTests {

    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ct-\(UUID().uuidString.prefix(8)).wav")
    }

    private func writeSineWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("finalize assembles chunk results with rebased word timings")
    func assemblesMultipleChunks() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 2.5)

        let fake = FakeClient(results: [
            TranscribeResult(
                text: "hello",
                words: [Word(text: "hello", startMs: 0, endMs: 500)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 10
            ),
            TranscribeResult(
                text: "world",
                words: [Word(text: "world", startMs: 0, endMs: 400)],
                speakers: [SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000)],
                processingMs: 12
            ),
            TranscribeResult(
                text: "tail",
                words: [Word(text: "tail", startMs: 0, endMs: 200)],
                speakers: [],
                processingMs: 5
            ),
        ])

        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        // Give the pump time to consume 2 full chunks.
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = Date().addingTimeInterval(-3)
        let end = Date()
        let result = try await transcriber.finalize(startedAt: start, endedAt: end)
        let transcript = result.transcript

        #expect(transcript.chunks.count == 3, "expected 2 full + 1 tail chunk, got \(transcript.chunks.count)")
        #expect(transcript.joinedText == "hello world tail")
        // Second chunk's "world" word was at chunk-local 0ms; should rebase to 1000ms.
        let worldWord = transcript.words.first { $0.text == "world" }
        #expect(worldWord?.startMs == 1000, "expected world rebased to 1000ms, got \(worldWord?.startMs ?? -1)")
        // Tail chunk's "tail" word was at chunk-local 0ms; should rebase to 2000ms.
        let tailWord = transcript.words.first { $0.text == "tail" }
        #expect(tailWord?.startMs == 2000)
    }

    @Test("vadEnabled:false forwards vad=false to client per chunk")
    func vadEnabledForwardsToClient() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        let fake = FakeClient(results: [
            TranscribeResult(text: "one", words: [], speakers: [], processingMs: 1),
            TranscribeResult(text: "two", words: [], speakers: [], processingMs: 1),
        ])

        let transcriber = ChunkedTranscriber(
            client: fake,
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        _ = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await fake.calls.first?.vad == false)
    }

    @Test("applies vocabulary to chunk text and joinedText")
    func vocabularyIsApplied() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        let fake = FakeClient(results: [
            TranscribeResult(
                text: "Arakeet is up",
                words: [Word(text: "Arakeet", startMs: 0, endMs: 500)],
                speakers: [],
                processingMs: 1
            ),
            TranscribeResult(
                text: "arakeet again",
                words: [Word(text: "arakeet", startMs: 0, endMs: 400)],
                speakers: [],
                processingMs: 1
            ),
        ])

        let vocab = Vocabulary(entries: [VocabularyEntry(from: "Arakeet", to: "Parakeet")])
        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            vocabulary: vocab,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        let finalized = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        let final = finalized.transcript
        // Both chunks rewritten with case preservation; joinedText reflects per-chunk passes.
        let chunkTexts = final.chunks.map(\.text)
        #expect(chunkTexts.contains("Parakeet is up"))
        #expect(chunkTexts.contains("parakeet again"))
        #expect(!final.joinedText.contains("Arakeet"))
    }
}

/// Fake client that throws `model_not_loaded` for the first N calls, then
/// succeeds — simulates a daemon still downloading the model on first run.
actor ModelWarmupClient: TranscribingClient {
    private var failuresRemaining: Int
    private(set) var calls: [String] = []
    private let successText: String

    init(failuresBeforeSuccess: Int, successText: String = "recovered") {
        self.failuresRemaining = failuresBeforeSuccess
        self.successText = successText
    }

    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        calls.append(audioPath)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ClientError.transcribeFailed(
                code: "model_not_loaded",
                message: "Model not loaded — call loadModels() first"
            )
        }
        return TranscribeResult(text: successText, words: [], speakers: [], processingMs: 1)
    }
}

@Suite("ChunkedTranscriber — model-not-loaded retry")
struct ChunkedTranscriberRetryTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ct-\(UUID().uuidString.prefix(8)).wav")
    }

    private func writeSineWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("chunk that fails with model_not_loaded is retried and recovered — no transcript hole")
    func modelNotLoadedChunkRecovers() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        // First two attempts fail (model downloading), third succeeds.
        let fake = ModelWarmupClient(failuresBeforeSuccess: 2)
        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.02,
            chunkRetryDelaySeconds: 0.02,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 300_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-2), endedAt: Date()
        )
        #expect(result.transcript.joinedText.contains("recovered"),
                "retried chunk should land in the transcript, got: \(result.transcript.joinedText)")
        #expect(await fake.calls.count >= 3)
    }

    @Test("every chunk failure is retried, and an exhausted chunk becomes a visible hole")
    func genericErrorsAreRetriedThenMarked() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        actor AlwaysFailingClient: TranscribingClient {
            private(set) var calls = 0
            func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
                calls += 1
                throw ClientError.transcribeFailed(code: "audio_load_failed", message: "corrupt")
            }
        }
        let fake = AlwaysFailingClient()
        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.02,
            chunkRetryDelaySeconds: 0.06,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-2), endedAt: Date()
        )
        // Retried beyond the first attempt — the old policy deleted the
        // chunk WAV on first failure, which is how a field recording lost
        // seven and a half minutes with one stderr line as the only witness.
        #expect(await fake.calls > 2)
        // The hole is part of the record now: a range, and a marker in the
        // transcript naming the repair path.
        let failed = await transcriber.failedRanges
        #expect(!failed.isEmpty)
        #expect(result.transcript.joinedText.contains("could not be transcribed"))
        #expect(result.transcript.joinedText.contains("Re-transcribe"))
    }

    @Test("an energetic chunk that comes back empty under VAD is retried without VAD")
    func vadEmptyFallsBackToUnvadded() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        // Full-scale sine: unambiguous audible energy.
        try writeSineWAV(to: url, seconds: 1.2)

        actor QuietRoomClient: TranscribingClient {
            private(set) var calls: [(vad: Bool, path: String)] = []
            func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
                calls.append((vad, audioPath))
                if vad {
                    // VAD classified the far-field speaker as silence.
                    return TranscribeResult(text: "", words: [], speakers: [], processingMs: 1)
                }
                return TranscribeResult(
                    text: "neal from across the room",
                    words: [Word(text: "neal", startMs: 0, endMs: 300)],
                    speakers: [], processingMs: 1
                )
            }
        }
        let fake = QuietRoomClient()
        let transcriber = ChunkedTranscriber(
            client: fake,
            vadEnabled: true,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.02,
            chunkRetryDelaySeconds: 0.02,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 300_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-2), endedAt: Date()
        )
        #expect(result.transcript.joinedText.contains("neal from across the room"))
        let calls = await fake.calls
        #expect(calls.contains { $0.vad == false }, "expected a no-VAD retry for the energetic empty chunk")
        #expect(await transcriber.failedRanges.isEmpty)
    }

    @Test("a shredded-but-nonempty VAD result is also retried, and the longer text wins")
    func sparseVadResultFallsBack() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.2)

        actor ShreddingClient: TranscribingClient {
            private(set) var calls: [(vad: Bool, path: String)] = []
            func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
                calls.append((vad, audioPath))
                if vad {
                    // The field-recording failure mode: VAD keeps a fragment
                    // and reports success. 96% of the minute is gone.
                    return TranscribeResult(text: "to", words: [], speakers: [], processingMs: 1)
                }
                return TranscribeResult(
                    text: "the full minute of what neal actually said about the renewal plan",
                    words: [], speakers: [], processingMs: 1
                )
            }
        }
        let fake = ShreddingClient()
        let transcriber = ChunkedTranscriber(
            client: fake,
            vadEnabled: true,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.02,
            chunkRetryDelaySeconds: 0.02,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 300_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-2), endedAt: Date()
        )
        #expect(result.transcript.joinedText.contains("what neal actually said"))
        #expect(!result.transcript.joinedText.contains("to\n"))
        #expect(await fake.calls.contains { $0.vad == false })
    }

    @Test("a genuinely silent chunk is not retried without VAD")
    func silentChunkStaysCheap() {
        // Below the −50 dBFS floor: hasAudibleEnergy must be false so the
        // fallback never fires on true silence.
        let url = URL(fileURLWithPath: "/tmp/harc-ct-silence-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try! AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000)!
        buf.frameLength = 16000
        for i in 0..<16000 { buf.floatChannelData![0][i] = Float.random(in: -0.0005...0.0005) }
        try! file.write(from: buf)

        #expect(!ChunkedTranscriber.hasAudibleEnergy(url))
    }

    @Test("late-retried chunks assemble in spoken order, not completion order")
    func retriedChunksStaySorted() {
        let assembler = TranscriptAssembler()
        // Chunk at 1000ms completes first (its transcribe succeeded
        // immediately); chunk at 0ms lands later after a model-wait retry.
        assembler.add(ChunkResult(
            startMs: 1000, endMs: 2000, text: "world",
            words: [Word(text: "world", startMs: 0, endMs: 300)],
            speakers: [], processingMs: 1
        ))
        assembler.add(ChunkResult(
            startMs: 0, endMs: 1000, text: "hello",
            words: [Word(text: "hello", startMs: 0, endMs: 300)],
            speakers: [], processingMs: 1
        ))
        #expect(assembler.currentJoinedText == "hello world")
        let final = assembler.finalize(startedAt: Date(), endedAt: Date(), audioPath: "/tmp/x.wav")
        #expect(final.joinedText == "hello world")
        #expect(final.words.map(\.text) == ["hello", "world"])
    }
}

actor FakeDiarizingClient: DiarizingClient {
    var calls: [String] = []
    var result: DiarizeResult = DiarizeResult(segments: [], speakers: [], processingMs: 0)
    var shouldThrow: Error?

    init(result: DiarizeResult = DiarizeResult(segments: [], speakers: [], processingMs: 0)) {
        self.result = result
    }

    func diarize(audioPath: String) async throws -> DiarizeResult {
        calls.append(audioPath)
        if let err = shouldThrow { throw err }
        return result
    }

    func setShouldThrow(_ err: Error?) { self.shouldThrow = err }
}

@Suite("ChunkedTranscriber — diarize")
struct ChunkedTranscriberDiarizeTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ct-\(UUID().uuidString.prefix(8)).wav")
    }

    private func writeSineWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("finalize calls diarize once on the full WAV and uses its segments")
    func finalizeRunsFullWAVDiarize() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 2.0)

        let fake = FakeClient(results: [
            TranscribeResult(text: "hi", words: [Word(text: "hi", startMs: 0, endMs: 200)],
                             speakers: [], processingMs: 1),
            TranscribeResult(text: "bye", words: [Word(text: "bye", startMs: 0, endMs: 200)],
                             speakers: [], processingMs: 1),
        ])
        let fakeDi = FakeDiarizingClient(result: DiarizeResult(
            segments: [
                SpeakerSegment(speaker: 0, startMs: 0, endMs: 1000),
                SpeakerSegment(speaker: 1, startMs: 1000, endMs: 2000),
            ],
            speakers: [
                SpeakerEmbeddingRow(
                    speakerIndex: 0,
                    vector: [Float](repeating: 0.0625, count: 256),
                    totalMs: 1000,
                    segmentCount: 1
                ),
                SpeakerEmbeddingRow(
                    speakerIndex: 1,
                    vector: [Float](repeating: 0.0625, count: 256),
                    totalMs: 1000,
                    segmentCount: 1
                ),
            ],
            processingMs: 50
        ))

        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            diarizer: fakeDi,
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-3),
            endedAt: Date()
        )

        #expect(await fakeDi.calls == [url.path])
        #expect(result.transcript.speakers.count == 2)
        #expect(result.speakerEmbeddings.count == 2)
        #expect(result.diarizationError == nil)
    }

    @Test("finalize tolerates diarize errors — transcript still returned")
    func finalizeToleratesDiarizeError() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.5)

        let fake = FakeClient(results: [
            TranscribeResult(text: "hi", words: [Word(text: "hi", startMs: 0, endMs: 200)],
                             speakers: [], processingMs: 1),
        ])
        let fakeDi = FakeDiarizingClient()
        await fakeDi.setShouldThrow(NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "diarize blew up"]
        ))

        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            diarizer: fakeDi,
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)

        let result = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-3),
            endedAt: Date()
        )

        #expect(result.transcript.joinedText.contains("hi"))
        #expect(result.transcript.speakers.isEmpty)
        #expect(result.speakerEmbeddings.isEmpty)
        #expect(result.diarizationError == "diarize blew up")
    }

    @Test("per-chunk transcribe always sends diarize=false")
    func perChunkSendsDiarizeFalse() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWAV(to: url, seconds: 1.5)

        let fake = FakeClient(results: [
            TranscribeResult(text: "hi", words: [], speakers: [], processingMs: 1),
        ])
        let transcriber = ChunkedTranscriber(
            client: fake,
            // Canned-result fakes: VAD fallback must not consume extra
            // queued results — these tests are not about VAD.
            vadEnabled: false,
            chunkDurationSeconds: 1.0,
            pollIntervalSeconds: 0.05,
            // Previews off: canned fakes must see only chunk-pump calls.
            livePreviewIntervalSeconds: 0,
            // Overlap off: these tests assert exact nominal chunk cadence.
            chunkOverlapSeconds: 0
        )
        await transcriber.start(audioURL: url)
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await transcriber.finalize(
            startedAt: Date().addingTimeInterval(-3), endedAt: Date()
        )

        #expect(await fake.calls.allSatisfy { $0.diarize == false })
    }
}

@Suite("ChunkedTranscriber live preview")
struct ChunkedTranscriberLivePreviewTests {

    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-ctlp-\(UUID().uuidString.prefix(8)).wav")
    }

    // MARK: - composeLivePreview (pure)

    @Test("the preview is appended after committed text")
    func appendsWholePreview() {
        let composed = ChunkedTranscriber.composeLivePreview(
            committedText: "hello world",
            previewText: "and then some"
        )
        #expect(composed == "hello world and then some")
    }

    @Test("an empty preview emits nothing")
    func emptyPreviewIsNil() {
        let composed = ChunkedTranscriber.composeLivePreview(
            committedText: "hello world",
            previewText: "   "
        )
        #expect(composed == nil)
    }

    @Test("with nothing committed the preview stands alone")
    func firstPreviewStandsAlone() {
        let composed = ChunkedTranscriber.composeLivePreview(
            committedText: "",
            previewText: "first words"
        )
        #expect(composed == "first words")
    }

    // MARK: - Integration

    @Test("preview updates reach the stream while no chunk has completed")
    func previewUpdatesFlow() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(2.5 * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        try file.write(from: buf)

        let canned = TranscribeResult(
            text: "live preview",
            words: [
                Word(text: "live", startMs: 0, endMs: 300),
                Word(text: "preview", startMs: 300, endMs: 700),
            ],
            speakers: [],
            processingMs: 5
        )
        let fake = FakeClient(results: Array(repeating: canned, count: 50))
        // 60 s chunks over a 2.5 s file: the chunk pump never completes a
        // chunk while recording, so any transcribe call before finalize is
        // a preview pass.
        let transcriber = ChunkedTranscriber(
            client: fake,
            vadEnabled: false,
            chunkDurationSeconds: 60.0,
            pollIntervalSeconds: 0.05,
            livePreviewIntervalSeconds: 0.1
        )
        await transcriber.start(audioURL: url)
        // The update itself is the synchronization point. Keep a generous
        // monotonic backstop so a preview regression fails instead of hanging
        // the entire test process when the stream stays open without values.
        let update = await withTaskGroup(of: TranscriptUpdate?.self) { group in
            group.addTask {
                for await update in await transcriber.updates { return update }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(180))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let callsBeforeStop = await fake.calls.count
        _ = try await transcriber.finalize(startedAt: Date(), endedAt: Date())

        #expect(callsBeforeStop >= 1, "expected at least one preview pass while recording")
        #expect(await fake.calls.prefix(callsBeforeStop).allSatisfy { $0.vad == false })
        #expect(update?.joinedTextSoFar == "live preview")
    }
}
