import AppKit
import Foundation

enum RecordingPermissionService: String, CaseIterable {
    case microphone = "Microphone"
    case screenCapture = "ScreenCapture"

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenCapture: return "Screen & System Audio Recording"
        }
    }
}

struct RecordingPermissionRepairPlan: Equatable {
    var bundleID: String
    var services: [RecordingPermissionService]

    var tccutilArguments: [[String]] {
        services.map { ["reset", $0.rawValue, bundleID] }
    }

    static func current(
        bundleID: String? = Bundle.main.bundleIdentifier,
        services: [RecordingPermissionService] = RecordingPermissionService.allCases
    ) -> RecordingPermissionRepairPlan? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return RecordingPermissionRepairPlan(bundleID: bundleID, services: services)
    }
}

enum RecordingPermissionRepair {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingBundleID
        case commandFailed(service: RecordingPermissionService, status: Int32)

        var errorDescription: String? {
            switch self {
            case .missingBundleID:
                return "Harc could not determine its app identifier."
            case .commandFailed(let service, let status):
                return "\(service.displayName) reset failed with status \(status)."
            }
        }
    }

    static func reset(plan: RecordingPermissionRepairPlan) throws {
        for service in plan.services {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service.rawValue, plan.bundleID]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw Error.commandFailed(service: service, status: process.terminationStatus)
            }
        }
    }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
