import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// Keeps a `RollingAudioBuffer` fed while no recording is running, so the user
/// can start a recording that reaches backwards in time.
///
/// This is the half of retroactive record that cloud tools cannot copy: it is
/// only affordable because capture and storage are local and metered by
/// nothing. Audio is held in memory and continuously overwritten — nothing is
/// written to disk, and nothing leaves the machine, until the user explicitly
/// promotes a window into a recording.
///
/// Mic only, deliberately. System audio via ScreenCaptureKit lights the screen
/// recording indicator for as long as it runs, and an always-on capture that
/// permanently flags the menu bar is a different (and much more alarming)
/// product than one that quietly keeps the last few minutes of the room. The
/// mic indicator that macOS shows is the honest signal here, and the user opts
/// into it.
///
/// Mutually exclusive with recording by construction: `AppDelegate` suspends
/// this before starting a `RecordingSession`, because both want the mic and the
/// pre-roll's whole purpose is to hand its contents over at that moment.
public actor PreRollCapture {
    /// How the capture is currently behaving. Exposed so the UI can be honest
    /// about whether the buffer is actually filling.
    public enum State: Equatable, Sendable {
        case stopped
        case listening
        /// Capture could not start or died. The reason is user-facing.
        case failed(String)
    }

    private let mic: any MicCaptureSource
    private let mixer = AudioMixer()
    private let buffer: RollingAudioBuffer
    private var pumpTask: Task<Void, Never>?
    private(set) public var state: State = .stopped

    public init(mic: any MicCaptureSource, windowSeconds: TimeInterval) {
        self.mic = mic
        self.buffer = RollingAudioBuffer(seconds: windowSeconds)
    }

    /// Seconds of audio currently banked and available to promote.
    public var bankedSeconds: TimeInterval { buffer.availableSeconds }

    /// Begin filling the ring. Idempotent — calling twice is a no-op rather
    /// than a second mic tap.
    public func start() async {
        guard state != .listening else { return }

        do {
            try await mic.requestPermission()
            let stream = try await mic.start()
            state = .listening
            pumpTask = Task { [weak self] in
                for await raw in stream {
                    await self?.ingest(raw)
                }
            }
        } catch {
            // Never fatal: failing to bank pre-roll must not prevent the user
            // from starting an ordinary recording.
            state = .failed(error.localizedDescription)
        }
    }

    private func ingest(_ raw: AVAudioPCMBuffer) {
        guard let mono = try? mixer.processMic(raw) else { return }
        buffer.append(mono)
    }

    /// Stop capturing and discard what was banked.
    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        await mic.stop()
        buffer.reset()
        state = .stopped
    }

    /// Hand over the banked audio for a recording to begin with, and clear the
    /// ring so the same seconds can never be prepended to a second recording.
    ///
    /// `seconds` trims to the most recent window; nil takes everything banked.
    /// Capture is stopped here too — the caller is about to take the mic.
    public func promote(seconds: TimeInterval? = nil) async -> [Int16] {
        let samples = buffer.snapshot(lastSeconds: seconds)
        await stop()
        return samples
    }

    /// Drop what's banked without stopping. The privacy escape hatch: the user
    /// says something they don't want retained and wipes the window without
    /// having to disable the feature.
    public func clear() {
        buffer.reset()
    }
}
