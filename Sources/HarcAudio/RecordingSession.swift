import Foundation
@preconcurrency import AVFoundation

/// Orchestrates a single recording. One instance per recording.
public actor RecordingSession {
    private let mic: any MicCaptureSource
    private let systemAudio: any SystemAudioCaptureSource
    private let destination: RecordingDestination

    // Processing state accessed from the pump task via nonisolated(unsafe).
    // Safe because the pump task is serialised: it runs sequentially (one buffer
    // at a time), and RecordingSession.stop() cancels + awaits the pump before
    // touching mixer or writer.
    nonisolated(unsafe) private let mixer = AudioMixer()
    nonisolated(unsafe) private var writer: AudioFileWriter?

    private var cacheURL: URL?
    private var startedAt: Date?
    private var pumpTask: Task<Void, Never>?
    private var systemAudioAvailable = false

    public init(
        mic: any MicCaptureSource,
        systemAudio: any SystemAudioCaptureSource,
        destination: RecordingDestination
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.destination = destination
    }

    public func start(at date: Date) async throws {
        // Permissions.
        try await mic.requestPermission()

        // System audio is optional — log and degrade on denial.
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

    public func stop() async throws -> URL {
        await mic.stop()
        await systemAudio.stop()
        pumpTask?.cancel()
        _ = await pumpTask?.value
        pumpTask = nil

        guard let writer, let cache = cacheURL, let startedAt else {
            throw AudioError.audioEngineFailed("stop called before start")
        }
        try writer.close()

        let dst = try destination.publicPath(for: startedAt)
        try RecordingDestination.atomicMove(from: cache, to: dst)
        self.writer = nil
        return dst
    }

    // Called from pumpStreams. Because mixer and writer are nonisolated(unsafe),
    // this can be nonisolated — no actor hop required, no Sendable issues.
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
            // Best-effort: log and continue. A transient conversion failure
            // shouldn't tear down the whole recording.
            FileHandle.standardError.write(Data(
                "harc-audio: processPair failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}

/// Free nonisolated function: iterates the mic stream, zips with the system stream (if any),
/// and calls the nonisolated processPair on the session. Running as a free function means
/// AsyncStream iterators (non-Sendable) stay as local vars and never cross isolation boundaries.
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
