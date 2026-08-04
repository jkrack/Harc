import UIKit

final class HarcMobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        HarcMobileBackgroundSessionBridge.shared.install(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@MainActor
final class HarcMobileBackgroundSessionBridge {
    static let shared = HarcMobileBackgroundSessionBridge()

    private var completionHandlers: [String: () -> Void] = [:]

    func install(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let prior = completionHandlers.updateValue(
            completionHandler,
            forKey: identifier
        ) {
            prior()
        }
        // The production URLSession adapter claims and completes this handler
        // only after durable ACK reconciliation. Keeping the UIKit entry point
        // here prevents an app-scene lifecycle from dropping a system relaunch.
    }

    func complete(identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }
}
