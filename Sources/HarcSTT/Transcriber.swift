import AVFoundation
import Foundation
import FluidAudio
import HarcCore

/// Wraps FluidAudio's ASR pipeline (Parakeet TDT v2 — English-only, per the
/// product constraint) for CoreML inference on ANE/Metal, with an optional
/// VAD pre-filter that strips silent regions and remaps Parakeet's
/// timestamps back to the original chunk timeline.
///
/// An experimental **Parakeet Unified EN** engine (`.unified`) is available
/// opt-in via `harc-stt --asr-engine unified`. The spike verdict (see
/// docs/dictation-plan.md): FluidAudio's `StreamingUnifiedAsrManager`
/// exposes `consumeWordTimings()` — word-level start/end on the global
/// timeline — so diarization alignment and per-word export keep working.
/// v2 stays the default until Unified has long-form mileage.
public actor Transcriber {
    /// Which ASR engine this daemon runs. Selected at spawn; not
    /// switchable per-request (each engine holds multi-hundred-MB models).
    public enum ASREngine: String, Sendable, Equatable {
        /// Parakeet TDT 0.6B v2 — the shipped default.
        case v2
        /// Parakeet Unified EN 0.6B via the streaming manager (experimental).
        case unified
    }

    /// Observable model lifecycle, reported over IPC via `DaemonStatus` so
    /// the app can tell the user the truth about first-run downloads.
    public enum ModelState: Sendable, Equatable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready
        case failed(message: String)
    }

    /// Parakeet version Harc ships. `.v2` is FluidAudio's own
    /// recommendation for English-only use (tighter vocabulary, better
    /// long-form recall than the multilingual `.v3`).
    static let asrVersion: AsrModelVersion = .v2

    public let engine: ASREngine
    private var asrManager: AsrManager?
    private var unifiedManager: StreamingUnifiedAsrManager?
    private let audioConverter = AudioConverter()
    private let vadGate: VADGate
    private var state: ModelState = .idle
    /// Failed loads retry on the next transcribe request, but not more
    /// often than this — an offline Mac shouldn't hammer Hugging Face.
    private var lastFailedLoadAt: Date?
    static let loadRetryCooldown: TimeInterval = 30
    /// Sample rate the VAD / stitcher / remapper operate at. Matches what
    /// AudioConverter.resampleAudioFile emits by default. Making this
    /// explicit prevents silent misbehaviour if the pipeline's audio
    /// format ever changes.
    private static let sampleRate: Int = 16000
    static let shortClipVADBypassSeconds: Double = 30.0

    public init(vadGate: VADGate = VADGate(), engine: ASREngine = .v2) {
        self.vadGate = vadGate
        self.engine = engine
    }

    public var isLoaded: Bool {
        switch engine {
        case .v2: return asrManager != nil
        case .unified: return unifiedManager != nil
        }
    }

    public var modelState: ModelState { state }

    /// Test hook: simulate a recent failed load so the on-demand retry
    /// cooldown path can be exercised without touching the network.
    func setLastFailedLoadForTesting(_ date: Date?) {
        lastFailedLoadAt = date
        if date != nil { state = .failed(message: "test-injected failure") }
    }

    /// One load at a time. `loadModels` suspends inside `downloadAndLoad`
    /// for minutes on a first run, and actor reentrancy means the startup
    /// preload, the first chunk request, and the live-preview pass can all
    /// re-enter during that window — each passing a naive `!isLoaded` guard
    /// and kicking off its own ~460 MB download. Everyone awaits the one
    /// in-flight load instead.
    private var loadTask: Task<Void, Error>?

    public func loadModels() async throws {
        guard !isLoaded else { return }
        if let existing = loadTask {
            try await existing.value
            return
        }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        guard !isLoaded else { return }
        state = .loading
        do {
            switch engine {
            case .v2:
                let manager = AsrManager(config: .default)
                let models = try await AsrModels.downloadAndLoad(
                    version: Self.asrVersion,
                    progressHandler: { [weak self] progress in
                        guard let self else { return }
                        // Progress arrives on an arbitrary queue; hop to the actor.
                        Task { await self.noteDownloadProgress(progress) }
                    }
                )
                try await manager.loadModels(models)
                self.asrManager = manager
            case .unified:
                let manager = StreamingUnifiedAsrManager()
                try await manager.loadModels(progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.noteDownloadProgress(progress) }
                })
                self.unifiedManager = manager
            }
        } catch {
            state = .failed(message: error.localizedDescription)
            lastFailedLoadAt = Date()
            throw error
        }
        state = .ready
        lastFailedLoadAt = nil
        // VAD is an optimisation — its failure must never block ASR load.
        do {
            try await vadGate.loadModel()
        } catch {
            FileHandle.standardError.write(Data(
                "harc-stt: VAD model load failed (\(error.localizedDescription)) — transcription will run without VAD\n".utf8
            ))
        }
    }

    private func noteDownloadProgress(_ progress: DownloadProgress) {
        // Only surface the download phase; compiling/loading is fast and
        // reported as `.loading`. Never regress out of ready/failed.
        guard state == .loading || isDownloadingState else { return }
        if case .downloading = progress.phase {
            state = .downloading(progress: progress.fractionCompleted)
        }
    }

    private var isDownloadingState: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// Pure decision: is a fresh load attempt allowed given the last
    /// failure time? Extracted for testability.
    static func shouldAttemptLoad(
        lastFailedAt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = loadRetryCooldown
    ) -> Bool {
        guard let lastFailedAt else { return true }
        return now.timeIntervalSince(lastFailedAt) >= cooldown
    }

    /// On-demand load retry: a daemon that failed its startup load (e.g.
    /// offline first launch) recovers on a later transcribe request once
    /// the cooldown has passed, instead of staying dead until restart.
    private func ensureEngineLoaded() async throws {
        if isLoaded { return }
        guard Self.shouldAttemptLoad(lastFailedAt: lastFailedLoadAt) else {
            throw DaemonError.modelNotLoaded
        }
        do {
            try await loadModels()
        } catch {
            throw DaemonError.modelNotLoaded
        }
        guard isLoaded else { throw DaemonError.modelNotLoaded }
    }

    public func transcribe(audioPath: String, vad: Bool) async throws -> TranscribeResult {
        try await ensureEngineLoaded()

        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(path: audioPath)
        } catch {
            throw DaemonError.audioLoadFailed(error.localizedDescription)
        }

        if !Self.shouldRunVAD(
            requested: vad,
            sampleCount: samples.count,
            sampleRate: Self.sampleRate
        ) {
            return try await runEngine(on: samples, regions: nil)
        }

        let vadStart = DispatchTime.now()
        let segments: [VadSegment]
        do {
            segments = try await vadGate.segments(in: samples)
        } catch {
            // Deliberately no file path — daemon.log persists on disk and
            // recording paths encode dates/meeting names.
            FileHandle.standardError.write(Data(
                "harc-stt: VAD failed (\(error.localizedDescription)) — falling back to full chunk transcription (\(samples.count) samples)\n".utf8
            ))
            return try await runEngine(on: samples, regions: nil)
        }
        let vadMs = Int((DispatchTime.now().uptimeNanoseconds - vadStart.uptimeNanoseconds) / 1_000_000)

        guard VADGate.hasMinimumVoicedDuration(segments) else {
            return TranscribeResult(text: "", words: [], speakers: [], processingMs: vadMs)
        }

        let stitch = VoicedStitcher.stitch(
            samples: samples,
            segments: segments,
            sampleRate: Self.sampleRate
        )
        return try await runEngine(on: stitch.compactSamples, regions: stitch.regions)
    }

    /// Engine dispatch — both engines share the VAD/stitch/remap pipeline.
    private func runEngine(
        on samples: [Float],
        regions: [VoicedRegion]?
    ) async throws -> TranscribeResult {
        switch engine {
        case .v2:
            guard let manager = asrManager else { throw DaemonError.modelNotLoaded }
            return try await runParakeet(on: samples, with: manager, regions: regions)
        case .unified:
            guard let manager = unifiedManager else { throw DaemonError.modelNotLoaded }
            return try await runUnified(on: samples, with: manager, regions: regions)
        }
    }

    /// Parakeet Unified EN via the streaming manager: feed the request's
    /// samples, flush, and drain word-level timings. State is reset per
    /// request — every chunk/clip is an independent utterance at Harc's
    /// IPC boundary, and the RNNT decoder state must not leak across.
    private func runUnified(
        on samples: [Float],
        with manager: StreamingUnifiedAsrManager,
        regions: [VoicedRegion]?
    ) async throws -> TranscribeResult {
        let start = DispatchTime.now()
        let text: String
        let timings: [WordTiming]
        do {
            try await manager.reset()
            guard let buffer = Self.pcmBuffer(from: samples, sampleRate: Self.sampleRate) else {
                throw DaemonError.audioLoadFailed("could not allocate PCM buffer")
            }
            try await manager.appendAudio(buffer)
            text = try await manager.finish()
            timings = await manager.consumeWordTimings()
        } catch let error as DaemonError {
            throw error
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let compactWords: [Word] = timings.map { t in
            Word(
                text: t.word,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }
        let words = regions.map {
            VADTimestampRemapper.remap(
                words: compactWords,
                regions: $0,
                sampleRate: Self.sampleRate
            )
        } ?? compactWords

        return TranscribeResult(
            text: text,
            words: words,
            speakers: [],
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }

    /// 16 kHz mono Float32 samples → AVAudioPCMBuffer for the streaming
    /// manager's `appendAudio`. Static + pure for testability.
    static func pcmBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private func runParakeet(
        on samples: [Float],
        with manager: AsrManager,
        regions: [VoicedRegion]?
    ) async throws -> TranscribeResult {
        let start = DispatchTime.now()
        let result: ASRResult
        do {
            // Fresh decoder state per request: every chunk/clip is an
            // independent utterance at Harc's IPC boundary. (FluidAudio 0.15
            // exposes the state so callers *can* carry it across windows;
            // Harc's chunk seams are stitched client-side instead.)
            var decoderState = try TdtDecoderState(
                decoderLayers: Self.asrVersion.decoderLayers
            )
            result = try await manager.transcribe(samples, decoderState: &decoderState)
        } catch {
            throw DaemonError.transcriptionFailed(error.localizedDescription)
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        let compactWords: [Word] = (result.tokenTimings ?? []).map { t in
            Word(
                text: t.token,
                startMs: Int(t.startTime * 1000),
                endMs: Int(t.endTime * 1000)
            )
        }
        let words = regions.map {
            VADTimestampRemapper.remap(
                words: compactWords,
                regions: $0,
                sampleRate: Self.sampleRate
            )
        } ?? compactWords

        return TranscribeResult(
            text: result.text,
            words: words,
            speakers: [],
            processingMs: Int(elapsedNs / 1_000_000)
        )
    }

    static func shouldRunVAD(
        requested: Bool,
        sampleCount: Int,
        sampleRate: Int
    ) -> Bool {
        guard requested else { return false }
        guard sampleRate > 0 else { return false }
        let durationSeconds = Double(sampleCount) / Double(sampleRate)
        return durationSeconds > shortClipVADBypassSeconds
    }
}
