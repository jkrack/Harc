import UIKit

/// Feedback supplements visible state; never enables haptics/system sounds during capture.
@MainActor
enum HarcMobileHaptics {
    enum Event: Equatable {
        case startRequested
        case recordingSaved
        case playbackStarted
        case failed
    }

    static func emit(_ event: Event) {
        guard UIApplication.shared.applicationState == .active else { return }
        switch event {
        case .startRequested:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
        case .recordingSaved:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .playbackStarted:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    static func captureEvent(
        from old: HarcMobileCaptureCoordinator.State,
        to new: HarcMobileCaptureCoordinator.State
    ) -> Event? {
        guard old != new else { return nil }
        switch new {
        case .saved: return .recordingSaved
        case .storageExhausted, .failed: return .failed
        default: return nil
        }
    }
}
