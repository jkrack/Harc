import Foundation
import Combine
import HarcAudio

/// Binding between AppDelegate's recording lifecycle and the SwiftUI popover.
/// AppDelegate mutates this on its own thread via the Main actor; SwiftUI views observe it.
@MainActor
public final class RecordingState: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    /// True from the moment a recording start is requested until the session
    /// actually starts (or fails). Capture no longer waits for speech-model
    /// launch, but audio-engine spin-up still suspends; any guard that reads
    /// only `isRecording` has a hole exactly that wide.
    @Published public private(set) var isPreparing: Bool = false
    @Published public private(set) var recordingStartedAt: Date? = nil
    /// Presentation-only Stop acceptance boundary. Capture/resource ownership
    /// remains active until the existing stop/finalization pipeline completes.
    @Published public private(set) var stopRequestedAt: Date? = nil
    public var isStopping: Bool { stopRequestedAt != nil }

    public func markStopRequested(at date: Date = Date()) {
        guard isActiveOrPreparing, stopRequestedAt == nil else { return }
        stopRequestedAt = date
    }

    /// Frozen at accepted Stop, not a claim about the final audio's duration.
    public func elapsedText(at now: Date = Date()) -> String {
        guard let start = recordingStartedAt else { return "0:00" }
        return ElapsedFormatter.string(since: start, now: stopRequestedAt ?? now)
    }

    /// The stopping surfaces outlive active timestamps during Library ingest.
    /// Omit the duration then instead of presenting a spurious zero.
    public var finishingElapsedText: String? {
        guard isStopping, recordingStartedAt != nil else { return nil }
        return elapsedText()
    }

    @Published public var livePreviewText: String = ""
    @Published public private(set) var lastResult: RecordingResult? = nil

    public init() {}

    /// The guard everything sharing the mic/daemon should read: a recording
    /// that is starting owns those resources as surely as one that is live.
    public var isActiveOrPreparing: Bool { isRecording || isPreparing }

    public func markPreparing() {
        stopRequestedAt = nil
        isPreparing = true
    }

    public func markStarted(at date: Date) {
        if !isPreparing { stopRequestedAt = nil }
        isPreparing = false
        isRecording = true
        recordingStartedAt = date
        livePreviewText = ""
    }

    public func markStopped(wavURL: URL, txtURL: URL?, jsonURL: URL?) {
        isPreparing = false
        isRecording = false
        recordingStartedAt = nil
        stopRequestedAt = nil
        livePreviewText = ""
        lastResult = RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    /// End a capture that was accepted by a non-standalone committer.
    /// There is intentionally no local canonical path to select. Clearing the
    /// previous standalone result prevents the recording-to-idle UI transition
    /// from navigating back to an older library row.
    public func markDeferredStop() {
        isPreparing = false
        isRecording = false
        recordingStartedAt = nil
        stopRequestedAt = nil
        livePreviewText = ""
        lastResult = nil
    }

    public func markIdle() {
        isPreparing = false
        isRecording = false
        recordingStartedAt = nil
        stopRequestedAt = nil
        livePreviewText = ""
    }

    public func appendPreview(_ text: String) {
        livePreviewText = text
    }
}
