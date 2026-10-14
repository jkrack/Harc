import AVFAudio
import Foundation
import Observation

@MainActor
protocol HarcMobileLocalAudioPlayer: AnyObject {
    var delegate: (any AVAudioPlayerDelegate)? { get set }
    var isPlaying: Bool { get }
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
    private let url: URL
    private var player: (any HarcMobileLocalAudioPlayer)?
    private let session: HarcMobilePlaybackSession
    private let makePlayer: (URL) throws -> any HarcMobileLocalAudioPlayer
    private var sessionOwner: UUID?

    init(
        url: URL,
        session: HarcMobilePlaybackSession = .shared,
        makePlayer: @escaping (URL) throws -> any HarcMobileLocalAudioPlayer = {
            try AVAudioPlayer(contentsOf: $0)
        }
    ) {
        self.url = url
        self.session = session
        self.makePlayer = makePlayer
    }

    func playOrPause() async {
        if let player {
            if player.isPlaying {
                player.pause()
                state = .paused
            } else if player.play() {
                state = .playing
            } else {
                stop()
                state = .failed("Harc could not resume local playback.")
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
            guard player.play() else {
                throw HarcMobileLocalPlaybackError.startFailed
            }
            state = .playing
        } catch {
            stop()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player = nil
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

