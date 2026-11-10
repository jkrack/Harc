import Darwin
import Foundation

/// A retryable scheduling deferral, never an integrity or receipt verdict.
public enum HostCanonicalResourceDeferred: Error, Equatable, Sendable, LocalizedError {
    case audioNotResident
    case insufficientCapacity
    case capacityUnavailable

    public var errorDescription: String? {
        switch self {
        case .audioNotResident:
            return "Canonical audio is not available locally. Background work will retry later."
        case .insufficientCapacity:
            return "Background audio work is waiting for sufficient free disk space."
        case .capacityUnavailable:
            return "Available disk space could not be verified. Background work will retry later."
        }
    }
}

/// Metadata-only admission for background audio work. Passing these checks
/// grants no content authority: signed evidence, exact identity, length and
/// hash validation remain mandatory. Residency can change after any check.
public struct HostCanonicalResourceAdmission: Sendable {
    public typealias Check = @Sendable (URL, UInt64) throws -> Void

    public let checkResidentAudio: Check
    public let checkCapacity: Check

    static let reserveBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024

    public init(
        checkResidentAudio: @escaping Check = { url, expectedByteCount in
            try HostCanonicalResourceAdmission.requireResidentAudio(
                at: url, expectedByteCount: expectedByteCount
            )
        },
        checkCapacity: @escaping Check = { url, additionalBytes in
            try HostCanonicalResourceAdmission.requireCapacity(
                at: url, additionalBytes: additionalBytes
            )
        }
    ) {
        self.checkResidentAudio = checkResidentAudio
        self.checkCapacity = checkCapacity
    }

    /// Uses lstat, not a content open or Foundation resource-value request that
    /// might hydrate an iCloud placeholder. Reserve room for the entire WAV
    /// even when resident, bounding the cost of eviction just after admission.
    public static func requireResidentAudio(at url: URL, expectedByteCount: UInt64) throws {
        try requireResidentAudio(
            at: url,
            expectedByteCount: expectedByteCount,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            metadata: { url in
                var information = stat()
                guard lstat(url.path, &information) == 0 else { return nil }
                return information
            },
            availableBytes: physicalAvailableBytes
        )
    }

    /// `url` must name an existing file or directory on the output volume.
    /// Unknown capacity fails closed. Home also needs the reserve because
    /// runtime, database and inference work can consume its internal volume.
    public static func requireCapacity(at url: URL, additionalBytes: UInt64) throws {
        try requireCapacity(
            at: url,
            additionalBytes: additionalBytes,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            availableBytes: physicalAvailableBytes
        )
    }

    // Synchronous metadata seams keep tests independent from real cloud files
    // and from the machine's current capacity. No fixture needs SF_DATALESS set.
    static func requireResidentAudio(
        at url: URL,
        expectedByteCount: UInt64,
        homeDirectory: URL,
        metadata: (URL) throws -> stat?,
        availableBytes: (URL) throws -> UInt64
    ) throws {
        try Task.checkCancellation()
        guard isAbsoluteFileURL(url) else {
            throw HostCanonicalResourceDeferred.audioNotResident
        }
        let information: stat?
        do {
            information = try metadata(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostCanonicalResourceDeferred.audioNotResident
        }
        try requireResidentMetadata(information)
        try requireCapacity(
            at: url,
            additionalBytes: expectedByteCount,
            homeDirectory: homeDirectory,
            availableBytes: availableBytes
        )
    }

    static func requireResidentMetadata(_ information: stat?) throws {
        guard let information else { throw HostCanonicalResourceDeferred.audioNotResident }
        // An existing unsafe entry is an integrity failure, not a retryable
        // availability condition. Check structure before placeholder flags.
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0
        else { throw HarcHostError.unsafePublicationPath }
        guard (information.st_flags & UInt32(SF_DATALESS)) == 0 else {
            throw HostCanonicalResourceDeferred.audioNotResident
        }
    }

    static func requireCapacity(
        at url: URL,
        additionalBytes: UInt64,
        homeDirectory: URL,
        availableBytes: (URL) throws -> UInt64
    ) throws {
        try Task.checkCancellation()
        guard isAbsoluteFileURL(url), isAbsoluteFileURL(homeDirectory) else {
            throw HostCanonicalResourceDeferred.capacityUnavailable
        }
        let required = reserveBytes.addingReportingOverflow(additionalBytes)
        guard !required.overflow else {
            throw HostCanonicalResourceDeferred.insufficientCapacity
        }
        let outputAvailable: UInt64
        let homeAvailable: UInt64
        do {
            outputAvailable = try availableBytes(url)
            homeAvailable = try availableBytes(homeDirectory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostCanonicalResourceDeferred.capacityUnavailable
        }
        guard outputAvailable >= required.partialValue,
              homeAvailable >= reserveBytes
        else { throw HostCanonicalResourceDeferred.insufficientCapacity }
        try Task.checkCancellation()
    }

    /// f_bavail is actual space available to this user. Do not substitute
    /// Foundation's "important usage" estimate, which includes purgeable data.
    private static func physicalAvailableBytes(at url: URL) throws -> UInt64 {
        var information = statfs()
        guard statfs(url.path, &information) == 0 else {
            throw HostCanonicalResourceDeferred.capacityUnavailable
        }
        return try availableByteCount(
            blocks: UInt64(exactly: information.f_bavail),
            blockSize: UInt64(exactly: information.f_bsize)
        )
    }

    static func availableByteCount(blocks: UInt64?, blockSize: UInt64?) throws -> UInt64 {
        guard let blocks, let blockSize, blockSize > 0 else {
            throw HostCanonicalResourceDeferred.capacityUnavailable
        }
        let bytes = blocks.multipliedReportingOverflow(by: blockSize)
        guard !bytes.overflow else {
            throw HostCanonicalResourceDeferred.capacityUnavailable
        }
        return bytes.partialValue
    }

    private static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0")
    }
}
