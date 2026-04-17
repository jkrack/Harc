import Testing
import Foundation
import AVFoundation
@testable import HarcAudio

@Suite("AudioFileWriter")
struct AudioFileWriterTests {
    private func tempWAVPath() -> URL {
        URL(fileURLWithPath: "/tmp/harc-wavwrite-\(UUID().uuidString.prefix(8)).wav")
    }

    /// Make a 16 kHz mono Float32 buffer filled with a sine wave at 440 Hz.
    private func makeSineBuffer(frames: AVAudioFrameCount, sampleRate: Double = 16000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = sinf(Float(2.0 * .pi * 440.0 * Double(i) / sampleRate))
        }
        return buf
    }

    @Test("writer produces a valid 16 kHz mono Int16 WAV with correct frame count")
    func producesValidWAV() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        try writer.write(makeSineBuffer(frames: 16000)) // 1 second of sine
        try writer.write(makeSineBuffer(frames: 16000)) // 1 more second
        try writer.close()

        let readback = try AVAudioFile(forReading: url)
        let processingFormat = readback.processingFormat
        #expect(readback.fileFormat.sampleRate == 16000)
        #expect(readback.fileFormat.channelCount == 1)
        #expect(readback.length == 32000, "expected 32000 frames, got \(readback.length)")
        _ = processingFormat
        // Confirm the on-disk format is Int16 PCM by reading the RIFF header.
        let data = try Data(contentsOf: url)
        // Walk RIFF chunks to find 'fmt ' (AVAudioFile may insert a JUNK pad chunk
        // before it, so we cannot assume a fixed offset of 34).
        var chunkOffset = 12
        var bps: UInt16 = 0
        while chunkOffset + 8 <= data.count {
            let id = String(bytes: data[chunkOffset..<(chunkOffset + 4)], encoding: .ascii) ?? ""
            let size = Int(UInt32(data[chunkOffset + 4]) | (UInt32(data[chunkOffset + 5]) << 8)
                        | (UInt32(data[chunkOffset + 6]) << 16) | (UInt32(data[chunkOffset + 7]) << 24))
            if id == "fmt " && chunkOffset + 8 + 16 <= data.count {
                // bits-per-sample is at byte 14 within the fmt chunk data (offset 22 from chunk start)
                bps = UInt16(data[chunkOffset + 22]) | (UInt16(data[chunkOffset + 23]) << 8)
                break
            }
            chunkOffset += 8 + size + (size % 2) // word-align
        }
        #expect(bps == 16, "expected 16-bit, got \(bps)")
    }

    @Test("writer.close is idempotent — second close does not throw")
    func closeIsIdempotent() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        try writer.write(makeSineBuffer(frames: 1600))
        try writer.close()
        try writer.close()
    }

    @Test("writer rejects buffers whose sample rate or channel count disagrees with the file")
    func rejectsMismatch() throws {
        let url = tempWAVPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url)
        let mismatched = makeSineBuffer(frames: 1600, sampleRate: 48000)
        #expect(throws: AudioError.self) {
            try writer.write(mismatched)
        }
        try writer.close()
    }
}
