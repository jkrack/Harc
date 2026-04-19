import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import HarcUI

@Suite("TranscriptAudioPlayer")
struct TranscriptAudioPlayerTests {
    private func writeSilenceWAV(to url: URL, seconds: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = 0 }
        try file.write(from: buf)
    }

    private func tempWAV() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-player-test-\(UUID().uuidString).wav")
    }

    @Test("load throws fileMissing for non-existent URL")
    func missing() async throws {
        let player = TranscriptAudioPlayer()
        let bogus = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav")
        await #expect(throws: AudioPlaybackError.self) {
            try await player.load(url: bogus)
        }
    }

    @Test("load + duration ≈ 1.0s on a 1-second fixture")
    func loadsAndReportsDuration() async throws {
        let url = tempWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilenceWAV(to: url, seconds: 1.0)

        let player = TranscriptAudioPlayer()
        try await player.load(url: url)
        let d = await player.duration
        #expect(d > 0.9 && d < 1.1)
    }

    @Test("seek clamps to [0, duration]")
    func seekClamps() async throws {
        let url = tempWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilenceWAV(to: url, seconds: 1.0)

        let player = TranscriptAudioPlayer()
        try await player.load(url: url)
        await player.seek(to: -10)
        #expect(await player.currentTime == 0)
        await player.seek(to: 999)
        let d = await player.duration
        #expect(await player.currentTime <= d)
    }

    @Test("play flips isPlaying; pause flips it back")
    func playPause() async throws {
        let url = tempWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilenceWAV(to: url, seconds: 1.0)

        let player = TranscriptAudioPlayer()
        try await player.load(url: url)
        await player.play()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await player.isPlaying)
        await player.pause()
        #expect(!(await player.isPlaying))
    }
}
