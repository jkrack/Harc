import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import HarcClient
import HarcCore

/// Result of a completed recording.
public struct RecordingResult: Sendable {
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?
    /// Per-speaker WeSpeaker centroid rows from the post-stop diarize pass.
    /// Empty when diarization was disabled, failed, or returned nothing.
    public let speakerEmbeddings: [SpeakerEmbeddingRow]
    /// Set when the diarize pass failed; the transcript text is still complete.
    /// UI layers surface a retry affordance from this.
    public let diarizationError: String?

    public init(
        wavURL: URL,
        txtURL: URL?,
        jsonURL: URL?,
        speakerEmbeddings: [SpeakerEmbeddingRow] = [],
        diarizationError: String? = nil
    ) {
        self.wavURL = wavURL
        self.txtURL = txtURL
        self.jsonURL = jsonURL
        self.speakerEmbeddings = speakerEmbeddings
        self.diarizationError = diarizationError
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

    /// Set to true when `start` had to fall back to mic-only because system
    /// audio capture failed (permission revoked, no display, etc.). The
    /// caller can read this AFTER `start` returns to surface a heads-up
    /// notification — without it, the user only sees their own voice in the
    /// transcript and other meeting participants are silently missing.
    public private(set) var systemAudioFellBack: Bool = false

    /// Seconds of retroactive audio prepended at `start`. Zero for an ordinary
    /// recording. Readable after `start` so the UI can say how far back the
    /// recording actually reaches.
    public private(set) var preRolledSeconds: Double = 0

    /// Fired once, on the first live-audio write failure (e.g. ENOSPC on the
    /// cache volume). Without it the session kept "recording" with animating
    /// levels while persisting nothing — the user learned an hour later, at
    /// transcription time. The owner should stop the session and tell the
    /// user; audio written before the failure is intact.
    nonisolated private let writeFailureLatch = OnceLatch()
    nonisolated private let onWriteFailure: (@Sendable (String) -> Void)?

    public init(
        mic: any MicCaptureSource,
        systemAudio: any SystemAudioCaptureSource,
        destination: RecordingDestination,
        transcriber: ChunkedTranscriber? = nil,
        onWriteFailure: (@Sendable (String) -> Void)? = nil
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.destination = destination
        self.transcriber = transcriber
        self.onWriteFailure = onWriteFailure
        var continuation: AsyncStream<AudioLevels>.Continuation!
        self.levels = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation = $0 }
        self.levelsContinuation = continuation
    }

    /// Begin recording.
    ///
    /// `preRoll` is banked audio from a `RollingAudioBuffer` — the retroactive
    /// record path. It is written into the WAV before any live audio, so the
    /// recording literally begins in the past, and `startedAt` is rolled back by
    /// its duration to keep every downstream timestamp honest: the transcript,
    /// the file name, and the library row all describe when the audio actually
    /// happened, not when the user got around to pressing the button.
    ///
    /// Writing it here — before `transcriber.start` — means the pre-roll flows
    /// through the ordinary chunking path rather than needing a second one.
    public func start(at date: Date, preRoll: [Int16] = []) async throws {
        try await mic.requestPermission()
        do {
            try await systemAudio.requestPermission()
            systemAudioAvailable = true
        } catch AudioError.systemAudioPermissionDenied {
            systemAudioAvailable = false
        }

        let cache = RecordingDestination.cachePath()
        self.cacheURL = cache
        let newWriter = try AudioFileWriter(url: cache)
        self.writer = newWriter

        var preRollFramesWritten = 0
        if !preRoll.isEmpty {
            for buffer in RollingAudioBuffer.buffers(from: preRoll) {
                // A failure here costs the retroactive window but must not stop
                // the live recording from starting — the meeting in front of the
                // user outranks the minutes behind them.
                do {
                    try newWriter.write(buffer)
                    preRollFramesWritten += Int(buffer.frameLength)
                } catch {
                    FileHandle.standardError.write(Data(
                        "harc-audio: pre-roll write failed: \(error.localizedDescription)\n".utf8
                    ))
                    break
                }
            }
        }
        // Timeline offset from what actually landed in the file, not from
        // what we intended to write: a mid-pre-roll failure leaves the
        // already-written buffers in the WAV, and zeroing the offset then
        // would shift every downstream timestamp (transcript ms,
        // ⌘-click-to-seek, word times) by the orphaned prefix's duration.
        let preRollSeconds = Double(preRollFramesWritten) / RollingAudioBuffer.sampleRate
        self.startedAt = date.addingTimeInterval(-preRollSeconds)
        self.preRolledSeconds = preRollSeconds

        if let transcriber {
            await transcriber.start(audioURL: cache)
        }

        let micStream = try await mic.start()
        let sysStream: AsyncStream<AVAudioPCMBuffer>?
        if systemAudioAvailable {
            do {
                sysStream = try await systemAudio.start()
            } catch {
                // System audio failed AFTER mic.start succeeded (permission revoked
                // between requestPermission and start, no display, addStreamOutput
                // error, etc.). Without this catch the throw escapes RecordingSession
                // .start, AppDelegate's catch nils out the session reference, and the
                // mic keeps running with no controller — the user sees the macOS mic
                // indicator but the app shows "Idle" and ⌥V can't stop it. Degrade
                // to mic-only instead.
                FileHandle.standardError.write(Data(
                    "harc-audio: system audio start failed, recording mic-only: \(error.localizedDescription)\n".utf8
                ))
                sysStream = nil
                systemAudioAvailable = false
                systemAudioFellBack = true
            }
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
        // Drain, don't cancel: both capture streams were just finished, so
        // the pump exits once it consumes what was already buffered.
        // Cancelling here discarded that backlog — the final fraction of a
        // second of the last utterance. The watchdog only covers a capture
        // source that fails to finish its stream.
        if let pumpTask {
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(5))
                pumpTask.cancel()
            }
            _ = await pumpTask.value
            watchdog.cancel()
        }
        pumpTask = nil
        levelsContinuation.finish()

        guard let writer, let cache = cacheURL, let startedAt else {
            throw AudioError.audioEngineFailed("stop called before start")
        }
        try writer.close()
        self.writer = nil

        // Finalize transcriber while cache file still exists.
        var finalTranscript: SessionTranscript? = nil
        var speakerEmbeddings: [SpeakerEmbeddingRow] = []
        var diarizationError: String? = nil
        if let transcriber {
            do {
                let finalized = try await transcriber.finalize(
                    startedAt: startedAt,
                    endedAt: Date()
                )
                finalTranscript = finalized.transcript
                speakerEmbeddings = finalized.speakerEmbeddings
                diarizationError = finalized.diarizationError
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
                txtURL = parent.appendingPathComponent("\(stem).md")
                jsonURL = parent.appendingPathComponent("\(stem).json")
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: transcript sibling write failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return RecordingResult(
            wavURL: wavURL,
            txtURL: txtURL,
            jsonURL: jsonURL,
            speakerEmbeddings: speakerEmbeddings,
            diarizationError: diarizationError
        )
    }

    /// Tear down a partially started session WITHOUT publishing anything.
    /// `stop()` unconditionally moves the cache WAV to the user's destination
    /// folder; calling it from a failed start deposited a ~44-byte junk WAV
    /// there on every attempt, which launch-time ingest then turned into a
    /// phantom "Recovered" library row. An aborted start leaves nothing
    /// behind: captures stopped, writer closed, cache file deleted.
    public func abort() async {
        await mic.stop()
        await systemAudio.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil
        levelsContinuation.finish()
        try? writer?.close()
        writer = nil
        if let transcriber {
            // Winds down the chunk pump/preview; the near-empty cache WAV
            // makes this cheap. Result intentionally discarded.
            _ = try? await transcriber.finalize(startedAt: startedAt ?? Date(), endedAt: Date())
        }
        if let cache = cacheURL {
            try? FileManager.default.removeItem(at: cache)
        }
        cacheURL = nil
    }

    /// Resample raw system-audio buffers and append them to `fifo`. Called only
    /// from the mix loop, so the mixer's system converter is never touched
    /// concurrently with `processPair`'s mic conversion.
    nonisolated fileprivate func ingestSystem(_ buffers: [AVAudioPCMBuffer], into fifo: SampleFIFO) {
        for buffer in buffers {
            do {
                fifo.append(try mixer.processSystem(buffer))
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: system resample failed: \(error.localizedDescription)\n".utf8
                ))
            }
        }
    }

    /// Mix one mic buffer with whatever system audio has accumulated, write the
    /// result, and emit display levels.
    ///
    /// The mic drives the cadence; `systemFIFO` holds resampled system samples
    /// that have not yet been consumed. We pull exactly as many system samples
    /// as the (resampled) mic buffer is long, so the WAV advances at mic
    /// real-time and any surplus system audio stays queued for the next tick
    /// rather than being dropped. `systemFIFO` is nil when system capture is
    /// off — then the mic mono buffer is written straight through.
    nonisolated fileprivate func processPair(mic: AVAudioPCMBuffer, systemFIFO: SampleFIFO?) {
        do {
            let micMono = try mixer.processMic(mic)
            let micDb = rmsDb(micMono)
            let sysMono = systemFIFO?.take(Int(micMono.frameLength), format: AudioMixer.targetFormat)
            let sysDb = sysMono.map(rmsDb) ?? -.infinity
            let mixed = try sysMono.map { try mixer.sum(mic: micMono, system: $0) } ?? micMono
            do {
                try writer?.write(mixed)
            } catch {
                FileHandle.standardError.write(Data(
                    "harc-audio: WAV write failed: \(error.localizedDescription)\n".utf8
                ))
                if writeFailureLatch.claim() {
                    onWriteFailure?(error.localizedDescription)
                }
            }
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
            session.processPair(mic: micBuffer, systemFIFO: nil)
        }
        return
    }

    let queue = SystemBufferQueue()

    // Drain the sys stream into a FIFO of raw buffers. This task only enqueues
    // — it never touches the mixer — so the mix loop below owns all conversion
    // single-threaded. Consumes every sys buffer so the producer can't stall.
    // Cancellation-safe.
    let sysTask = Task.detached { [queue, carrier = StreamCarrier(stream: sysStream)] in
        for await buf in carrier.stream {
            await queue.put(buf)
        }
    }

    // Mic drives the mix cadence. On each mic tick we resample every system
    // buffer that has arrived since the last tick into a sample FIFO, then mix
    // the mic buffer with an equal span of system samples. Surplus system audio
    // stays in the FIFO rather than being dropped — the fix for choppy system
    // audio when ScreenCaptureKit delivers buffers faster than the mic.
    let systemFIFO = SampleFIFO()
    for await micBuffer in micStream {
        session.ingestSystem(await queue.drain().buffers, into: systemFIFO)
        session.processPair(mic: micBuffer, systemFIFO: systemFIFO)
    }

    sysTask.cancel()
    _ = await sysTask.value
}

/// Thread-safe fire-once flag for the write-failure signal.
final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
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

/// FIFO mailbox for raw system-audio buffers between the sys-drain task and the
/// mix loop. The drain task appends every buffer; the mix loop drains the whole
/// queue on each mic tick. `cap` bounds memory if the mix loop ever stalls —
/// the oldest buffers are shed rather than growing without limit.
private actor SystemBufferQueue {
    private var buffers: [PCMBox] = []
    private let cap = 256

    func put(_ buffer: AVAudioPCMBuffer) {
        buffers.append(PCMBox(buffer: buffer))
        if buffers.count > cap {
            buffers.removeFirst(buffers.count - cap)
        }
    }

    func drain() -> PCMBatch {
        defer { buffers.removeAll(keepingCapacity: true) }
        return PCMBatch(buffers: buffers.map(\.buffer))
    }
}

/// Sendable envelope for a batch of system buffers handed from the drain actor
/// to the (nonisolated) mix loop. Same rationale as `PCMBox`: the buffers are
/// effectively immutable once produced by the capture source.
private struct PCMBatch: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
}
