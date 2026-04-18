import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import HarcClient

/// Result of a completed recording.
public struct RecordingResult: Sendable {
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?
}

/// Orchestrates a single recording. One instance per recording.
public actor RecordingSession {
    private let mic: any MicCaptureSource
    private let systemAudio: any SystemAudioCaptureSource
    private let destination: RecordingDestination
    private let transcriber: ChunkedTranscriber?

    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?

    private var cacheURL: URL?
    private var startedAt: Date?
    private var pumpTask: Task<Void, Never>?
    private var systemAudioAvailable = false

    public init(
        mic: any MicCaptureSource,
        systemAudio: any SystemAudioCaptureSource,
        destination: RecordingDestination,
        transcriber: ChunkedTranscriber? = nil
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.destination = destination
        self.transcriber = transcriber
    }

    public func start(at date: Date) async throws {
        try await mic.requestPermission()
        do {
            try await systemAudio.requestPermission()
            systemAudioAvailable = true
        } catch AudioError.systemAudioPermissionDenied {
            systemAudioAvailable = false
        }

        let cache = RecordingDestination.cachePath()
        self.cacheURL = cache
        self.startedAt = date
        self.writer = try AudioFileWriter(url: cache)

        if let transcriber {
            await transcriber.start(audioURL: cache)
        }

        let micStream = try await mic.start()
        let sysStream: AsyncStream<AVAudioPCMBuffer>?
        if systemAudioAvailable {
            sysStream = try await systemAudio.start()
        } else {
            sysStream = nil
        }

        self.pumpTask = Task.detached { [self, micStream, sysStream] in
            await pumpStreams(session: self, mic: micStream, system: sysStream)
        }
    }

    public func stop() async throws -> RecordingResult {
        await mic.stop()
        await systemAudio.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        guard let writer, let cache = cacheURL, let startedAt else {
            throw AudioError.audioEngineFailed("stop called before start")
        }
        try writer.close()
        self.writer = nil

        // Finalize transcriber while cache file still exists.
        var finalTranscript: SessionTranscript? = nil
        if let transcriber {
            do {
                finalTranscript = try await transcriber.finalize(
                    startedAt: startedAt,
                    endedAt: Date()
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: transcription finalize failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        // Now move the WAV to its public location.
        let wavURL = try destination.publicPath(for: startedAt)
        try RecordingDestination.atomicMove(from: cache, to: wavURL)

        // Write sibling files at the final location with the final path.
        var txtURL: URL? = nil
        var jsonURL: URL? = nil
        if var transcript = finalTranscript {
            transcript.audioPath = wavURL.path
            do {
                try TranscriptWriter.writeSiblings(transcript: transcript, nextTo: wavURL)
                let stem = wavURL.deletingPathExtension().lastPathComponent
                let parent = wavURL.deletingLastPathComponent()
                txtURL = parent.appendingPathComponent("\(stem).txt")
                jsonURL = parent.appendingPathComponent("\(stem).json")
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: transcript sibling write failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    nonisolated fileprivate func processPair(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer?) {
        do {
            let micMono = try mixer.processMic(mic)
            let mixed: AVAudioPCMBuffer
            if let system {
                let sysMono = try mixer.processSystem(system)
                mixed = try mixer.sum(mic: micMono, system: sysMono)
            } else {
                mixed = micMono
            }
            try writer?.write(mixed)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: processPair failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}

private func pumpStreams(
    session: RecordingSession,
    mic micStream: AsyncStream<AVAudioPCMBuffer>,
    system sysStream: AsyncStream<AVAudioPCMBuffer>?
) async {
    if let sysStream {
        var sysIter = sysStream.makeAsyncIterator()
        for await micBuffer in micStream {
            let sysBuffer = await sysIter.next()
            session.processPair(mic: micBuffer, system: sysBuffer)
        }
    } else {
        for await micBuffer in micStream {
            session.processPair(mic: micBuffer, system: nil)
        }
    }
}
