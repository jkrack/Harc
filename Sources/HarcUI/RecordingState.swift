import Foundation
import Combine
import HarcAudio

/// Binding between AppDelegate's recording lifecycle and the SwiftUI popover.
/// AppDelegate mutates this on its own thread via the Main actor; SwiftUI views observe it.
@MainActor
public final class RecordingState: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var recordingStartedAt: Date? = nil
    @Published public var livePreviewText: String = ""
    @Published public private(set) var lastResult: RecordingResult? = nil

    public init() {}

    public func markStarted(at date: Date) {
        isRecording = true
        recordingStartedAt = date
        livePreviewText = ""
    }

    public func markStopped(wavURL: URL, txtURL: URL?, jsonURL: URL?) {
        isRecording = false
        recordingStartedAt = nil
        livePreviewText = ""
        lastResult = RecordingResult(wavURL: wavURL, txtURL: txtURL, jsonURL: jsonURL)
    }

    public func markIdle() {
        isRecording = false
        recordingStartedAt = nil
        livePreviewText = ""
    }

    public func appendPreview(_ text: String) {
        livePreviewText = text
    }
}
