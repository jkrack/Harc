import Foundation
@preconcurrency import AVFoundation

public enum AudioPlaybackError: Error, LocalizedError {
    case fileMissing(URL)
    case fileUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let url): return "Audio file not found at \(url.path)."
        case .fileUnreadable(let msg): return "Audio file couldn't be read: \(msg)."
        }
    }
}

/// Thin `AVAudioPlayer` wrapper. Actor-isolated so concurrent reads of
/// `currentTime` during playback polling are safe. Pure playback — no
/// recording, no ScreenCaptureKit, no mixing.
public actor TranscriptAudioPlayer {
    private var player: AVAudioPlayer?

    public init() {}

    public func load(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileMissing(url)
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            self.player = p
        } catch {
            throw AudioPlaybackError.fileUnreadable(error.localizedDescription)
        }
    }

    public func play() {
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    /// Seek clamped to `[0, duration]`.
    public func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, player.duration))
        player.currentTime = clamped
    }

    public var currentTime: Double {
        player?.currentTime ?? 0
    }

    public var duration: Double {
        player?.duration ?? 0
    }

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }
}
