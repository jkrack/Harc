import Foundation
import UserNotifications

/// Post-stop macOS notification fired after Harc auto-stops a recording.
/// Carries two actions — **Resume** (start a new linked recording) and
/// **Open Transcript** (open the most-recent capture in the library).
///
/// The notification is additive to the tray banner, never the only signal:
/// DND may suppress it, and the banner in the tray persists until dismissed.
public enum AutoStopNotification {
    public static let categoryID = "harc.autoStopped"
    public static let resumeActionID = "harc.autoStopped.resume"
    public static let openActionID = "harc.autoStopped.open"
    public static let identifier = "harc.autoStopped"

    /// Register the category + actions with UNUserNotificationCenter. Safe to
    /// call repeatedly; we merge with any other categories the app has set.
    public static func registerCategory() {
        let resume = UNNotificationAction(
            identifier: resumeActionID,
            title: "Resume",
            options: [.foreground]
        )
        let open = UNNotificationAction(
            identifier: openActionID,
            title: "Open Transcript",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [resume, open],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        Task {
            var existing = await center.notificationCategories()
            existing.insert(category)
            center.setNotificationCategories(existing)
        }
    }

    /// Post the auto-stop notification. Silently no-op if the user hasn't
    /// granted notification permission.
    public static func post(
        reason: AutoStopController.StopReason,
        duration: TimeInterval?,
        thresholdMinutes: Int,
        previewText: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Harc"
        content.subtitle = "Recording auto-stopped"
        content.body = body(reason: reason, duration: duration, thresholdMinutes: thresholdMinutes)
        if let snippet = previewSnippet(from: previewText) {
            content.body += "\n\n“\(snippet)”"
        }
        content.categoryIdentifier = categoryID
        content.threadIdentifier = identifier
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    public static func withdraw() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // MARK: - Body copy

    private static func body(
        reason: AutoStopController.StopReason,
        duration: TimeInterval?,
        thresholdMinutes: Int
    ) -> String {
        let durationPart = duration.map { formatDuration($0) + " · " } ?? ""
        switch reason {
        case .silence:
            return "\(durationPart)no audio for \(thresholdMinutes) min."
        case .hardCap:
            return "\(durationPart)hit max recording length."
        case .captureStalled:
            return "\(durationPart)audio capture stopped. Audio up to that point was saved."
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    private static func previewSnippet(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Last sentence-ish chunk — prefer the tail of the transcript so the
        // user sees something that implies "we just stopped."
        let tail = String(trimmed.suffix(120))
        return tail
    }
}
