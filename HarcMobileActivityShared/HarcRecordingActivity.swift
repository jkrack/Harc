import ActivityKit
import AppIntents
import Foundation

struct HarcRecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var updatedAt: Date
        var durableAudioSeconds: Int
    }

    let captureID: String
    let startedAt: Date
}

/// LiveActivityIntent executes in the app process. Binding to the exact live
/// capture prevents a delayed action from affecting a subsequent recording.
@MainActor
enum HarcRecordingActivityActions {
    static var captureID: String?
    static var stop: (() -> Void)?

    static func stop(captureID requestedID: String) {
        guard captureID == requestedID else { return }
        stop?()
    }
}

struct StopHarcRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Harc recording"
    static let description = IntentDescription("Stop and save this recording on your iPhone.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Recording") var captureID: String

    init() {}
    init(captureID: String) { self.captureID = captureID }

    @MainActor
    func perform() async throws -> some IntentResult {
        HarcRecordingActivityActions.stop(captureID: captureID)
        return .result()
    }
}
