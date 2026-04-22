import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import HarcClient

/// Result of a completed recording.
public struct RecordingResult: Sendable {
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?

    public init(wavURL: URL, txtURL: URL?, jsonURL: URL?) {
        self.wavURL = wavURL
        self.txtURL = txtURL
        self.jsonURL = jsonURL
    }
}

/// RMS + FFT level snapshot per audio tick. Drives both the live scope and
/// menu bar bars, and is the same signal the silence-detection trigger reads
/// — one source of truth for "is there audio right now".
///
/// - `micDb` / `systemDb`: raw per-tick RMS of the individual streams, in
///   dBFS. `-.infinity` if that stream had no frames.
/// - `smoothedDb`: RMS of the weighted (mic 0.7 + sys 0.3) signal with a
///   20 ms attack / 200 ms release envelope, clamped to `[-60, 0]` dBFS.
///   This is the value the auto-stop timer checks against the silence
///   threshold.
/// - `fftBins`: 5 normalized band magnitudes of the weighted signal in
///   `[0, 1]` — bass, low-mid, mid, high-mid, sibilance.
public struct AudioLevels: Sendable {
    public let micDb: Float
    public let systemDb: Float
    public let smoothedDb: Float
    public let fftBins: [Float]

    public init(micDb: Float, systemDb: Float, smoothedDb: Float, fftBins: [Float]) {
        self.micDb = micDb
        self.systemDb = systemDb
        self.smoothedDb = smoothedDb
        self.fftBins = fftBins
    }
}

/// Orchestrates a single recording. One instance per recording.
public actor RecordingSession {
    private let mic: any MicCaptureSource
    private let systemAudio: any SystemAudioCaptureSource
    private let destination: RecordingDestination
    private let transcriber: ChunkedTranscriber?

    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?
    nonisolated(unsafe) private let levelComputer = LevelComputer()

    /// Live RMS + FFT level stream — one tick per mic buffer. Consumers can
    /// drop this on the floor if no one subscribes; the continuation is buffered
    /// with `.bufferingNewest(2)` so a slow consumer only sees the latest values.
    public nonisolated let levels: AsyncStream<AudioLevels>
    nonisolated private let levelsContinuation: AsyncStream<AudioLevels>.Continuation

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
        var continuation: AsyncStream<AudioLevels>.Continuation!
        self.levels = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation = $0 }
        self.levelsContinuation = continuation
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
        levelsContinuation.finish()

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
            let micDb = rmsDb(micMono)
            let sysMono: AVAudioPCMBuffer?
            let sysDb: Float
            let mixed: AVAudioPCMBuffer
            if let system {
                let mono = try mixer.processSystem(system)
                sysMono = mono
                sysDb = rmsDb(mono)
                mixed = try mixer.sum(mic: micMono, system: mono)
            } else {
                sysMono = nil
                sysDb = -.infinity
                mixed = micMono
            }
            try writer?.write(mixed)
            let levels = levelComputer.compute(
                micMono: micMono,
                systemMono: sysMono,
                micDb: micDb,
                systemDb: sysDb
            )
            levelsContinuation.yield(levels)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-audio: processPair failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    /// RMS of a mono Float32 buffer in dBFS. Floor at -120 dB so a totally
    /// silent buffer yields a finite number (`-.infinity` if there are no frames).
    nonisolated private func rmsDb(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData?[0] else { return -.infinity }
        var sum: Float = 0
        for i in 0..<count {
            let s = data[i]
            sum += s * s
        }
        let mean = sum / Float(count)
        guard mean > 0 else { return -120 }
        let rms = sqrtf(mean)
        return max(-120, 20 * log10f(rms))
    }
}

private func pumpStreams(
    session: RecordingSession,
    mic micStream: AsyncStream<AVAudioPCMBuffer>,
    system sysStream: AsyncStream<AVAudioPCMBuffer>?
) async {
    guard let sysStream else {
        for await micBuffer in micStream {
            session.processPair(mic: micBuffer, system: nil)
        }
        return
    }

    let latest = LatestSystemBuffer()

    // Drain the sys stream into the latest-slot. Consumes every sys buffer
    // so the writer can't stall; the mic pump picks whichever arrived most
    // recently on each mic tick. Cancellation-safe.
    let sysTask = Task.detached { [latest, carrier = StreamCarrier(stream: sysStream)] in
        for await buf in carrier.stream {
            await latest.put(buf)
        }
    }

    // Mic drives the mix cadence. Each mic buffer reads the latest sys buffer
    // (or nil if none has arrived since last read) and mixes accordingly.
    for await micBuffer in micStream {
        let sysBox = await latest.take()
        session.processPair(mic: micBuffer, system: sysBox?.buffer)
    }

    sysTask.cancel()
    _ = await sysTask.value
}

/// Sendable envelope for an `AVAudioPCMBuffer`. PCM buffers aren't annotated
/// `Sendable` in the SDK, but they're effectively immutable once produced by a
/// capture source, so it's safe to hand one off between tasks.
private struct PCMBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Sendable envelope for an `AsyncStream<AVAudioPCMBuffer>`. The stream itself
/// is safe to hand across tasks; the compiler only flags it because its
/// element type isn't `Sendable`.
private struct StreamCarrier: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
}

/// Single-slot mailbox for the most recent system-audio buffer.
/// The sys-drain task overwrites the slot; the mic pump consumes it on each tick.
/// `take()` returns nil if no new sys buffer has arrived since the last read —
/// the pump treats that as "mic-only for this tick."
private actor LatestSystemBuffer {
    private var current: PCMBox?

    func put(_ buffer: AVAudioPCMBuffer) {
        current = PCMBox(buffer: buffer)
    }

    func take() -> PCMBox? {
        let b = current
        current = nil
        return b
    }
}
