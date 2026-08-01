import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Minimal mic-only recorder for dictation. Captures the microphone to a
/// temporary 16 kHz mono WAV and emits a live level (0…1) per buffer. Unlike
/// `RecordingSession` it does not touch system audio, chunked transcription,
/// or the durable destination hierarchy — dictation clips are short and
/// disposable.
public protocol DictationRecording: Sendable {
    /// Live capture level in 0…1 (normalized RMS), one value per mic buffer.
    /// Finishes when capture stops.
    nonisolated var levels: AsyncStream<Float> { get }
    /// Begin capture. Throws on mic-permission denial / engine failure.
    func start() async throws
    /// Stop capture and return the finished WAV file URL.
    func stop() async throws -> URL
    /// Stop capture and discard the file.
    func cancel() async
    /// The growing capture WAV while recording — the streaming-preview
    /// pass reads windows out of it (#97). Nil when unsupported or idle.
    func currentAudioURL() async -> URL?
}

public extension DictationRecording {
    func currentAudioURL() async -> URL? { nil }
}

public actor MicDictationRecorder: DictationRecording {
    private let mic: any MicCaptureSource
    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?

    public nonisolated let levels: AsyncStream<Float>
    nonisolated private let levelsContinuation: AsyncStream<Float>.Continuation

    private var cacheURL: URL?
    private var pumpTask: Task<Void, Never>?

    public init(mic: any MicCaptureSource = MicCapture()) {
        self.mic = mic
        var cont: AsyncStream<Float>.Continuation!
        self.levels = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { cont = $0 }
        self.levelsContinuation = cont
    }

    public func start() async throws {
        try await mic.requestPermission()
        let cache = Self.newCacheURL()
        self.cacheURL = cache
        self.writer = try AudioFileWriter(url: cache)
        let stream = try await mic.start()
        self.pumpTask = Task.detached { [self, carrier = DictationStreamCarrier(stream: stream)] in
            for await buffer in carrier.stream {
                self.ingest(buffer)
            }
        }
    }

    /// `nonisolated` so the pump task can call it without hopping the actor and
    /// without moving the non-Sendable buffer across an isolation boundary.
    /// The pump is the only caller and runs single-threaded, so the
    /// `nonisolated(unsafe)` mixer/writer are never touched concurrently.
    nonisolated private func ingest(_ buffer: AVAudioPCMBuffer) {
        do {
            let mono = try mixer.processMic(buffer)
            try writer?.write(mono)
            levelsContinuation.yield(Self.level(mono))
        } catch {
            // Best-effort: drop a bad buffer rather than tearing down capture.
        }
    }

    public func currentAudioURL() async -> URL? {
        cacheURL
    }

    public func stop() async throws -> URL {
        await finishCapture()
        guard let cache = cacheURL else {
            throw AudioError.audioEngineFailed("dictation stop called before start")
        }
        try writer?.close()
        writer = nil
        cacheURL = nil
        return cache
    }

    public func cancel() async {
        await finishCapture()
        try? writer?.close()
        writer = nil
        if let cache = cacheURL {
            try? FileManager.default.removeItem(at: cache)
        }
        cacheURL = nil
    }

    private func finishCapture() async {
        await mic.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil
        levelsContinuation.finish()
    }

    static func newCacheURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Harc/dictation", isDirectory: true)
        return dir.appendingPathComponent(UUID().uuidString + ".wav")
    }

    /// Normalized 0…1 level from a mono Float32 buffer (RMS mapped from −60…0 dBFS).
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0, let d = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += d[i] * d[i] }
        let rms = sqrtf(sum / Float(n))
        let db = rms > 0 ? 20 * log10f(rms) : -60
        let clamped = max(-60, min(0, db))
        return (clamped + 60) / 60
    }
}

/// Sendable envelope for an `AsyncStream<AVAudioPCMBuffer>` — the stream is safe
/// to hand across tasks; the compiler only flags it because the element type
/// isn't `Sendable`.
private struct DictationStreamCarrier: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
}
