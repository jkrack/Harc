import HarcClientTransport
@preconcurrency import UIKit

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
    private final class CompletionBox: @unchecked Sendable {
        private let completion: () -> Void

        init(_ completion: @escaping () -> Void) {
            self.completion = completion
        }

        func call() {
            completion()
        }
    }

    static let shared = HarcMobileBackgroundSessionBridge()

    private var client: HarcBackgroundURLSessionUploadClientV1?
    private var completionHandlers: [String: CompletionBox] = [:]

    func attach(_ client: HarcBackgroundURLSessionUploadClientV1) {
        self.client = client
        let pending = completionHandlers
        completionHandlers.removeAll()
        for (identifier, completionHandler) in pending {
            installOnClient(
                client,
                identifier: identifier,
                completionHandler: completionHandler
            )
        }
    }

    func install(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let completion = CompletionBox(completionHandler)
        if let client {
            installOnClient(
                client,
                identifier: identifier,
                completionHandler: completion
            )
            return
        }
        if let prior = completionHandlers.updateValue(
            completion,
            forKey: identifier
        ) {
            prior.call()
        }
    }

    private func installOnClient(
        _ client: HarcBackgroundURLSessionUploadClientV1,
        identifier: String,
        completionHandler: CompletionBox
    ) {
        do {
            try client.installBackgroundEventsCompletionHandler(
                sessionIdentifier: identifier,
                completionHandler: { completionHandler.call() }
            )
        } catch {
            // Foundation must never be left waiting if an invalid or duplicate
            // identifier reaches the application boundary.
            completionHandler.call()
        }
    }
}
