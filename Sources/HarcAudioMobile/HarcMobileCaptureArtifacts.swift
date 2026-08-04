import Foundation

public enum HarcMobileCaptureStoragePolicy: String, Sendable {
    case activeMaster
    case transferArtifact

    #if os(iOS)
    var protection: FileProtectionType {
        switch self {
        case .activeMaster: .completeUnlessOpen
        case .transferArtifact: .completeUntilFirstUserAuthentication
        }
    }
    #endif
}

public protocol HarcMobileCaptureStorageAttributeApplying: Sendable {
    func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws
}

public struct FoundationHarcMobileCaptureStorageAttributes:
    HarcMobileCaptureStorageAttributeApplying, Sendable
{
    public init() {}

    public func applyAndVerify(
        _ policy: HarcMobileCaptureStoragePolicy,
        to url: URL
    ) throws {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw HarcMobileCaptureStorageError.missingArtifact(url.path)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        guard try mutableURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true else {
            throw HarcMobileCaptureStorageError.backupExclusionNotApplied(
                url.path
            )
        }

        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: policy.protection],
            ofItemAtPath: url.path
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard attributes[.protectionKey] as? FileProtectionType
                == policy.protection else {
            throw HarcMobileCaptureStorageError.protectionNotApplied(url.path)
        }
        #endif
    }
}

public struct HarcMobileCaptureLocations: Equatable, Sendable {
    public let root: URL
    public let active: URL
    public let finalized: URL

    public init(applicationSupportRoot: URL) throws {
        guard applicationSupportRoot.isFileURL else {
            throw HarcMobileCaptureStorageError.nonFileURL(
                applicationSupportRoot.absoluteString
            )
        }
        root = applicationSupportRoot.standardizedFileURL
            .appendingPathComponent("Capture", isDirectory: true)
        active = root.appendingPathComponent("Active", isDirectory: true)
        finalized = root.appendingPathComponent("Finalized", isDirectory: true)
    }

    public func prepare(
        attributes: any HarcMobileCaptureStorageAttributeApplying
    ) throws {
        for directory in [root, active, finalized] {
            try HarcMobileCaptureFileSystem.requireSafeDirectory(directory)
            try attributes.applyAndVerify(.transferArtifact, to: directory)
        }
        try HarcMobileCaptureFileSystem.synchronizeDirectory(root)
    }

    public func partialMasterURL(recordingUUID: UUID) -> URL {
        active.appendingPathComponent(
            "\(recordingUUID.uuidString.lowercased()).wav.partial"
        )
    }

    public func checkpointURL(recordingUUID: UUID) -> URL {
        active.appendingPathComponent(
            "\(recordingUUID.uuidString.lowercased()).capture.json"
        )
    }

    public func finalizedMasterURL(recordingUUID: UUID) -> URL {
        finalized.appendingPathComponent(
            "\(recordingUUID.uuidString.lowercased()).wav"
        )
    }
}

public enum HarcMobileCaptureStorageError: Error, Equatable, Sendable {
    case nonFileURL(String)
    case unsafeArtifact(String)
    case missingArtifact(String)
    case backupExclusionNotApplied(String)
    case protectionNotApplied(String)
    case posix(operation: String, code: Int32)
    case corruptCheckpoint(String)
    case invalidCanonicalBytes
    case writerClosed
    case destinationExists(String)
}
