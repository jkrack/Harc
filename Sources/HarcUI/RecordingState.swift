import Foundation
import Combine
import HarcAudio

/// Binding between AppDelegate's recording lifecycle and the SwiftUI popover.
/// AppDelegate mutates this on its own thread via the Main actor; SwiftUI views observe it.
@MainActor
public final class RecordingState: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    /// True from the moment a recording start is requested until the session
    /// actually starts (or fails). The start path awaits daemon launch and
    /// audio-engine spin-up for whole seconds; any guard that reads only
    /// `isRecording` has a hole exactly that wide — dictation, imports, and
    /// the pre-roll ring all used to slip through it.
    @Published public private(set) var isPreparing: Bool = false
    @Published public private(set) var recordingStartedAt: Date? = nil
    @Published public var livePreviewText: String = ""
    @Published public private(set) var lastResult: RecordingResult? = nil

    public init() {}

    /// The guard everything sharing the mic/daemon should read: a recording
    /// that is starting owns those resources as surely as one that is live.
    public var isActiveOrPreparing: Bool { isRecording || isPreparing }

    public func markPreparing() {
        isPreparing = true
    }

    public func markStarted(at date: Date) {
        isPreparing = false
        isRecording = true
        recordingStartedAt = date
        livePreviewText = ""
    }

    public func markStopped(wavURL: URL, txtURL: URL?, jsonURL: URL?) {
        isPreparing = false
        isRecording = false
        recordingStartedAt = nil
        livePreviewText = ""
        lastResult = RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    public func markIdle() {
        isPreparing = false
        isRecording = false
        recordingStartedAt = nil
        livePreviewText = ""
    }

    public func appendPreview(_ text: String) {
        livePreviewText = text
    }
}
