import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcClient

@Suite("WAVChunker")
struct WAVChunkerTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-chunker-\(UUID().uuidString.prefix(8)).wav")
    }

    /// Writes `seconds` of 16 kHz mono 16-bit PCM sine at 440 Hz to `url`.
    /// Returns the AVAudioFile reference kept open so the caller can append more.
    private func openGrowingWAV(url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    private func appendSine(_ file: AVAudioFile, seconds: Double, freq: Double = 440) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * freq * Double(i) / 16000.0))
        }
        try file.write(from: buf)
    }

    @Test("chunker produces a 1 second chunk when audio has exceeded 1 s")
    func singleChunk() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 1.5)
        // Dropping the reference flushes the RIFF header.
        _ = file
        let _: AVAudioFile? = nil

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        let chunk = try await chunker.nextChunk()
        #expect(chunk != nil, "expected a chunk")
        if let chunk {
            defer { try? FileManager.default.removeItem(at: chunk.audioURL) }
            #expect(chunk.startMs == 0)
            #expect(chunk.endMs == 1000)
            let readback = try AVAudioFile(forReading: chunk.audioURL)
            #expect(readback.length == 16000, "expected 16000 frames, got \(readback.length)")
        }
        let second = try await chunker.nextChunk()
        #expect(second == nil, "no second full chunk yet (only 0.5s remains)")
    }

    @Test("chunker yields multiple chunks as audio grows")
    func multipleChunks() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 3.2)
        _ = file

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        var chunks: [WAVChunker.Chunk] = []
        while let c = try await chunker.nextChunk() {
            chunks.append(c)
        }
        #expect(chunks.count == 3)
        #expect(chunks[0].startMs == 0 && chunks[0].endMs == 1000)
        #expect(chunks[1].startMs == 1000 && chunks[1].endMs == 2000)
        #expect(chunks[2].startMs == 2000 && chunks[2].endMs == 3000)

        let tail = try await chunker.flush()
        #expect(tail != nil)
        if let tail {
            defer { try? FileManager.default.removeItem(at: tail.audioURL) }
            #expect(tail.startMs == 3000)
            // Remaining 0.2s = 3200 frames
            let readback = try AVAudioFile(forReading: tail.audioURL)
            #expect(readback.length == 3200, "expected tail 3200 frames, got \(readback.length)")
        }

        for c in chunks { try? FileManager.default.removeItem(at: c.audioURL) }
    }

    @Test("previewWindow slices the tail without consuming anything")
    func previewWindowNonConsuming() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 3.0)

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        // Anchored at 0 with a 2 s cap over 3 s of audio: the cap wins.
        let window = try await chunker.previewWindow(fromMs: 0, maxSeconds: 2.0)
        #expect(window != nil)
        if let window {
            defer { try? FileManager.default.removeItem(at: window.audioURL) }
            #expect(window.startMs == 1000)
            #expect(window.endMs == 3000)
            let readback = try AVAudioFile(forReading: window.audioURL)
            #expect(readback.length == 32000)
        }
        // Anchored past 0: the boundary wins over the cap.
        let anchored = try await chunker.previewWindow(fromMs: 1500, maxSeconds: 60.0)
        #expect(anchored?.startMs == 1500)
        #expect(anchored?.endMs == 3000)
        if let anchored { try? FileManager.default.removeItem(at: anchored.audioURL) }
        // The previews consumed nothing: the next chunk still starts at zero.
        let first = try await chunker.nextChunk()
        #expect(first?.startMs == 0)
        if let first { try? FileManager.default.removeItem(at: first.audioURL) }
        _ = file
    }

    @Test("previewWindow is nil until a second of new audio exists")
    func previewWindowTiny() async throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try openGrowingWAV(url: url)
        try appendSine(file, seconds: 1.5)

        let chunker = WAVChunker(audioURL: url, chunkDurationSeconds: 1.0)
        // Only 0.5 s exists past the anchor — not enough for a preview.
        let window = try await chunker.previewWindow(fromMs: 1000, maxSeconds: 60.0)
        #expect(window == nil)
        _ = file
    }
}
