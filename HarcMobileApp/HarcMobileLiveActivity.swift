@preconcurrency import ActivityKit
import Foundation
import OSLog

/// Best-effort presentation only. ActivityKit failure must never fail capture.
@MainActor
final class HarcMobileLiveActivity {
    private var activity: Activity<HarcRecordingActivityAttributes>?
    private var durableSeconds: () -> Double = { 0 }
    private var heartbeat: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.harc.HarcMobile", category: "LiveActivity")

    init() {
        // Capture the old set now; never sweep up a subsequently started session.
        let abandoned = Activity<HarcRecordingActivityAttributes>.activities
        Task {
            for old in abandoned { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(startedAt: Date, durableSeconds: @escaping () -> Double, stop: @escaping () -> Void) {
        self.durableSeconds = durableSeconds
        let captureID = UUID().uuidString
        HarcRecordingActivityActions.captureID = captureID
        HarcRecordingActivityActions.stop = stop
        let previous = Activity<HarcRecordingActivityAttributes>.activities
        Task {
            for old in previous {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: HarcRecordingActivityAttributes(captureID: captureID, startedAt: startedAt),
                content: content(phase: "Recording"),
                pushType: nil
            )
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    guard let self, let activity = self.activity else { return }
                    await activity.update(self.content(phase: "Recording"))
                }
            }
        } catch {
            logger.error("Could not present recording activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() {
        heartbeat?.cancel()
        heartbeat = nil
        HarcRecordingActivityActions.stop = nil
        HarcRecordingActivityActions.captureID = nil
        guard let activity else { return }
        self.activity = nil
        let finalContent = content(phase: "Recording ended")
        Task { await activity.end(finalContent, dismissalPolicy: .immediate) }
    }

    private func content(phase: String) -> ActivityContent<HarcRecordingActivityAttributes.ContentState> {
        ActivityContent(state: .init(phase: phase, updatedAt: .now, durableAudioSeconds: Int(max(0, durableSeconds()))), staleDate: .now.addingTimeInterval(45))
    }
}
