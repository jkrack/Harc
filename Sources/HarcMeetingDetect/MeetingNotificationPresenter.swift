import Foundation
import UserNotifications

public enum MeetingNotification {
    public static let categoryID = "harc.meetingDetected"
    public static let recordActionID = "harc.meetingDetected.record"
    public static let dismissActionID = "harc.meetingDetected.dismiss"
    public static let bundleIDUserInfoKey = "bundleID"
    public static let appIDUserInfoKey = "appID"
}

@MainActor
public final class MeetingNotificationPresenter {
    public enum AuthStatus { case authorized, denied, notDetermined }

    public init() {}

    /// Register the custom category with its Record / Dismiss actions.
    /// Safe to call multiple times.
    public func registerCategory() {
        let record = UNNotificationAction(
            identifier: MeetingNotification.recordActionID,
            title: "Record",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: MeetingNotification.dismissActionID,
            title: "Not now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: MeetingNotification.categoryID,
            actions: [record, dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Returns current authorization status, requesting if `.notDetermined`.
    public func ensureAuthorization() async -> AuthStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return ok ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    /// Post the "Meeting detected" banner. No-op if not authorized.
    public func present(app: MeetingApp) async {
        let status = await ensureAuthorization()
        guard status == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.subtitle = "\(app.displayName) is now running"
        content.body = "Start recording this meeting with Harc?"
        content.categoryIdentifier = MeetingNotification.categoryID
        content.threadIdentifier = app.bundleID
        content.userInfo = [
            MeetingNotification.bundleIDUserInfoKey: app.bundleID,
            MeetingNotification.appIDUserInfoKey: app.id,
        ]
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "harc.meetingDetected.\(app.bundleID)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    public func withdraw(bundleID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["harc.meetingDetected.\(bundleID)"]
        )
    }
}
