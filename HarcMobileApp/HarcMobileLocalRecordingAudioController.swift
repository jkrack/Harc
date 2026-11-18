import AVFAudio
import Foundation
import Observation
import OSLog

@MainActor
protocol HarcMobileLocalAudioPlayer: AnyObject {
    var delegate: (any AVAudioPlayerDelegate)? { get set }
    var isPlaying: Bool { get }
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    @discardableResult func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: HarcMobileLocalAudioPlayer {}

@MainActor
@Observable
final class HarcMobileLocalRecordingAudioController: NSObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var envelope: [Float] = []
    private var pendingTime: TimeInterval = 0
    private var envelopeTask: Task<Void, Never>?
    private var preparationGeneration: UInt64 = 0
    private var hasPreparedEnvelope = false

    var currentTime: TimeInterval { player?.currentTime ?? pendingTime }
    var canSeek: Bool { duration.isFinite && duration > 0 }

    func seek(to time: TimeInterval) {
        guard time.isFinite, canSeek else { return }
        pendingTime = min(duration, max(0, time))
        player?.currentTime = pendingTime
    }

    /// Read display data without claiming the playback session or interrupting capture.
    func prepare() async {
        guard !Task.isCancelled else { return }
        startPreparation()
        let task = envelopeTask
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            task?.cancel()
        }
    }

    private func startPreparation() {
        guard envelopeTask == nil, !hasPreparedEnvelope else { return }
        preparationGeneration &+= 1
        let generation = preparationGeneration
        let url = url
        let worker = Task.detached(priority: .utility) {
            try? Self.readDisplayData(url: url)
        }
        envelopeTask = Task { [weak self] in
            let data = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, generation == preparationGeneration else { return }
            envelopeTask = nil
            guard !Task.isCancelled, let data else { return }
            // A live player's duration is authoritative when playback has begun.
            if player == nil { duration = data.duration }
            envelope = data.envelope
            hasPreparedEnvelope = true
        }
    }

    nonisolated private static func readDisplayData(url: URL) throws -> DisplayData {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let envelope = try HarcMobileRecordingAudioController.readEnvelope(url: url)
        try Task.checkCancellation()
        return DisplayData(duration: duration.isFinite ? max(0, duration) : 0, envelope: envelope)
    }

    private struct DisplayData: Sendable {
        var duration: TimeInterval
        var envelope: [Float]
    }

    private let url: URL
    private let onPlaybackStarted: () -> Void
    private var player: (any HarcMobileLocalAudioPlayer)?
    private let session: HarcMobilePlaybackSession
    private let makePlayer: (URL) throws -> any HarcMobileLocalAudioPlayer
    private var sessionOwner: UUID?

    init(
        url: URL,
        session: HarcMobilePlaybackSession = .shared,
        onPlaybackStarted: @escaping () -> Void = { HarcMobileHaptics.emit(.playbackStarted) },
        makePlayer: @escaping (URL) throws -> any HarcMobileLocalAudioPlayer = {
            try AVAudioPlayer(contentsOf: $0)
        }
    ) {
        self.url = url
        self.onPlaybackStarted = onPlaybackStarted
        self.session = session
        self.makePlayer = makePlayer
    }

    func playOrPause() async {
        HarcSyntheticPlaybackTrace.emit(.playEntered)
        if let player {
            if player.isPlaying {
                player.pause()
                state = .paused
                HarcSyntheticPlaybackTrace.emit(.paused)
            } else {
                do {
                    try session.reactivate(sessionOwner)
                    if player.currentTime >= duration { player.currentTime = 0 }
                    guard player.play() else { throw HarcMobileLocalPlaybackError.startFailed }
                    state = .playing
                    HarcSyntheticPlaybackTrace.emit(.resumed)
                    onPlaybackStarted()
                } catch {
                    stop()
                    state = .failed(error.localizedDescription)
                    HarcSyntheticPlaybackTrace.emit(.failed)
                }
            }
            return
        }
        state = .loading
        do {
            sessionOwner = try session.acquire { [weak self] in self?.stop() }
            let player = try makePlayer(url)
            player.delegate = self
            self.player = player
            player.prepareToPlay()
            duration = player.duration.isFinite ? max(0, player.duration) : 0
            player.currentTime = min(duration, max(0, pendingTime))
            if player.currentTime >= duration { player.currentTime = 0 }
            guard player.play() else {
                throw HarcMobileLocalPlaybackError.startFailed
            }
            state = .playing
            HarcSyntheticPlaybackTrace.emit(.started)
            onPlaybackStarted()
            startPreparation()
        } catch {
            stop()
            state = .failed(error.localizedDescription)
            HarcSyntheticPlaybackTrace.emit(.failed)
        }
    }

    func stop() {
        HarcSyntheticPlaybackTrace.emit(.stopped)
        preparationGeneration &+= 1
        envelopeTask?.cancel()
        envelopeTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        pendingTime = 0
        if state != .idle {
            state = .idle
        }
        releaseSession()
    }

    private func releaseSession() {
        guard let owner = sessionOwner else { return }
        sessionOwner = nil
        session.release(owner)
    }

    func playbackFinished(_ finished: any HarcMobileLocalAudioPlayer, successfully flag: Bool) {
        guard let player, player === finished else { return }
        HarcSyntheticPlaybackTrace.emit(.finished)
        pendingTime = flag ? duration : player.currentTime
        player.delegate = nil
        self.player = nil
        state = flag ? .idle : .failed("Local playback ended unexpectedly.")
        releaseSession()
    }
}

extension HarcMobileLocalRecordingAudioController:
    @preconcurrency AVAudioPlayerDelegate
{
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        playbackFinished(player, successfully: flag)
    }
}

private enum HarcMobileLocalPlaybackError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        "Harc could not start local playback."
    }
}


/// Opt-in, synthetic-only diagnostic. Closed events, no content or identities.
@MainActor
enum HarcSyntheticPlaybackTrace {
    enum Event: String {
        case tap, handler, playEntered, resumed, started, paused, failed
        case stopped, finished, detailDisappeared, sessionAcquire, sessionRevoke, captureBegin
    }
    private static var count = 0
    static func emit(_ event: Event) {
        #if DEBUG
        let info = ProcessInfo.processInfo
        guard info.environment["HARC_SYNTHETIC_PLAYBACK_TRACE"] == "1",
              info.arguments.contains("--harc-ui-test-local-recording"),
              info.arguments.contains("--harc-ui-test-reset-root"),
              info.arguments.contains("--harc-ui-test-root-id"), count < 40 else { return }
        count += 1
        Logger(subsystem: "com.harc.mobile.syntheticplayback", category: "event")
            .notice("event=\(event.rawValue, privacy: .public) sequence=\(count)")
        #endif
    }
}
