import Testing
import Foundation
@preconcurrency import AVFoundation
import HarcCore
@testable import HarcClient

/// Input duration is measured from each actual synthetic WAV passed to inference.
/// No wall-clock scheduling assertion or real model is needed for the budget.
private actor PreviewBudgetClient: TranscribingClient {
    private(set) var inputMilliseconds: [Int] = []
    private var texts: [String]

    init(texts: [String]) { self.texts = texts }

    func transcribe(audioPath: String, diarize: Bool, vad: Bool) async throws -> TranscribeResult {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        inputMilliseconds.append(Int(Double(file.length) * 1_000 / file.processingFormat.sampleRate))
        let text = texts.isEmpty ? "unexpected inference" : texts.removeFirst()
        return TranscribeResult(text: text, words: [], speakers: [], processingMs: 0)
    }
}

@Suite("Live preview budget")
struct LivePreviewBudgetTests {
    @Test("preview uses its configured bound and never enters final transcript")
    func boundedPreviewIsProvisional() async throws {
        let url = try sineWAV(seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreviewBudgetClient(texts: ["provisional", "complete final transcript"])
        let transcriber = makeTranscriber(client: client, budget: 3)
        await transcriber.start(audioURL: url)
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds == [2_500])
        let result = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await client.inputMilliseconds == [2_500, 2_500])
        #expect(result.transcript.joinedText == "complete final transcript")
        #expect(result.transcript.chunks.map(\.startMs) == [0])
        #expect(result.transcript.chunks.map(\.endMs) == [2_500])
        #expect(await transcriber.failedRanges.isEmpty)
    }

    @Test("over-budget tail defers inference without consuming or losing audio")
    func defersPartialTail() async throws {
        let url = try sineWAV(seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreviewBudgetClient(texts: ["complete final transcript"])
        let transcriber = makeTranscriber(client: client, budget: 1)
        await transcriber.start(audioURL: url)
        await transcriber.emitPreview()
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds.isEmpty)
        let result = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await client.inputMilliseconds == [2_500])
        #expect(result.transcript.joinedText == "complete final transcript")
        #expect(result.transcript.chunks.map(\.startMs) == [0])
        #expect(result.transcript.chunks.map(\.endMs) == [2_500])
        #expect(await transcriber.failedRanges.isEmpty)
    }

    @Test("growing past budget retains the prior preview until final commit")
    func retainsPreviewWhileDeferred() async throws {
        let url = try sineWAV(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreviewBudgetClient(texts: ["retained provisional words", "complete final transcript"])
        let transcriber = makeTranscriber(client: client, budget: 2)
        await transcriber.start(audioURL: url)
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds == [1_500])

        // Recreate the same synthetic PCM file with an identical prefix and
        // additional audio. Both lengths are below the durable chunk size.
        _ = try sineWAV(seconds: 3.5, at: url)
        await transcriber.emitPreview()
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds == [1_500])

        let result = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        // Finalize closes the stream. Reading all buffered events proves there
        // was no empty, partial-tail, or replacement event while deferred,
        // without a sleep-based assertion that nothing happened.
        var updates: [String] = []
        for await update in await transcriber.updates {
            updates.append(update.joinedTextSoFar)
        }
        #expect(updates == ["retained provisional words", "complete final transcript"])
        #expect(await client.inputMilliseconds == [1_500, 3_500])
        #expect(result.transcript.joinedText == "complete final transcript")
        #expect(result.transcript.chunks.map(\.startMs) == [0])
        #expect(result.transcript.chunks.map(\.endMs) == [3_500])
        #expect(await transcriber.failedRanges.isEmpty)
    }

    @Test("preview resumes after a durable chunk advances the boundary")
    func resumesAfterCommit() async throws {
        let url = try sineWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreviewBudgetClient(texts: ["committed", "provisional tail", "durable tail"])
        let transcriber = makeTranscriber(client: client, budget: 2, chunkSeconds: 3)
        await transcriber.start(audioURL: url)
        // Synchronize with the real chunk commit rather than assuming a sleep
        // lets the pump run. AsyncStream iteration is cancellation-responsive.
        let first = await withTaskGroup(of: TranscriptUpdate?.self) { group in
            group.addTask {
                for await update in await transcriber.updates { return update }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
        #expect(first?.joinedTextSoFar == "committed")
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds == [3_000, 2_000])
        let result = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await client.inputMilliseconds == [3_000, 2_000, 2_000])
        #expect(result.transcript.joinedText == "committed durable tail")
        #expect(result.transcript.chunks.map(\.startMs) == [0, 3_000])
        #expect(result.transcript.chunks.map(\.endMs) == [3_000, 5_000])
        #expect(await transcriber.failedRanges.isEmpty)
    }

    @Test("invalid preview budgets disable only speculative inference", arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func invalidBudget(_ budget: Double) async throws {
        let url = try sineWAV(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PreviewBudgetClient(texts: ["complete"])
        let transcriber = makeTranscriber(client: client, budget: budget)
        await transcriber.start(audioURL: url)
        await transcriber.emitPreview()
        #expect(await client.inputMilliseconds.isEmpty)
        let result = try await transcriber.finalize(startedAt: Date(), endedAt: Date())
        #expect(await client.inputMilliseconds == [1_500])
        #expect(result.transcript.joinedText == "complete")
    }

    private func makeTranscriber(client: PreviewBudgetClient, budget: Double, chunkSeconds: Double = 60) -> ChunkedTranscriber {
        ChunkedTranscriber(
            client: client, vadEnabled: false, chunkDurationSeconds: chunkSeconds,
            pollIntervalSeconds: 60, livePreviewIntervalSeconds: 0,
            livePreviewWindowSeconds: budget, chunkOverlapSeconds: 0
        )
    }

    private func sineWAV(seconds: Double, at existingURL: URL? = nil) throws -> URL {
        let url = existingURL ?? URL(fileURLWithPath: "/tmp/harc-preview-budget-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let count = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for frame in 0..<Int(count) {
            buffer.floatChannelData![0][frame] = sinf(Float(2 * .pi * 440 * Double(frame) / 16_000))
        }
        try file.write(from: buffer)
        return url
    }
}
