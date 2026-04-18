import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import Darwin

/// Writes 16 kHz mono Int16 PCM WAV incrementally. Caller must serialize
/// `write(_:)` and `close()`; not safe for concurrent use. Call `close()`
/// when done (idempotent).
public final class AudioFileWriter {
    public static let targetSampleRate: Double = 16000
    public static let targetChannels: AVAudioChannelCount = 1

    private let url: URL
    private var file: AVAudioFile?
    private var lastFsync = Date()
    private let fsyncInterval: TimeInterval = 5.0

    public init(url: URL) throws {
        self.url = url

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFileWriter.targetSampleRate,
            AVNumberOfChannelsKey: AudioFileWriter.targetChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw AudioError.fileWriteFailed("open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Append a buffer. The buffer's format must match the writer's target
    /// (16 kHz, 1 channel). If it doesn't, the call throws; callers (e.g.
    /// AudioMixer) are responsible for converting first.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        guard buffer.format.sampleRate == AudioFileWriter.targetSampleRate,
              buffer.format.channelCount == AudioFileWriter.targetChannels
        else {
            throw AudioError.conversionFailed(
                "expected \(Int(AudioFileWriter.targetSampleRate))Hz / \(AudioFileWriter.targetChannels)ch, " +
                "got \(Int(buffer.format.sampleRate))Hz / \(buffer.format.channelCount)ch"
            )
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioError.fileWriteFailed("write: \(error.localizedDescription)")
        }
        try fsyncIfDue()
    }

    /// Force an fsync if the interval has elapsed. Exposed for tests; normally
    /// called transparently by `write(_:)`.
    public func fsyncIfDue() throws {
        guard Date().timeIntervalSince(lastFsync) >= fsyncInterval else { return }
        try fsyncFileAtURL()
        lastFsync = Date()
    }

    public func close() throws {
        guard file != nil else { return }
        // Dropping the reference triggers the AVAudioFile writer's finalization.
        self.file = nil
        // Final fsync to flush the RIFF header update.
        try? fsyncFileAtURL()
    }

    private func fsyncFileAtURL() throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else {
            throw AudioError.fileWriteFailed("open for fsync failed: errno \(errno)")
        }
        defer { Darwin.close(fd) }
        if Darwin.fsync(fd) != 0 {
            throw AudioError.fileWriteFailed("fsync failed: errno \(errno)")
        }
    }
}
