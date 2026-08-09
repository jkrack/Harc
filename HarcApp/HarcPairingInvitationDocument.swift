import AppKit
import Darwin
import Foundation
import HarcProtocol
import UniformTypeIdentifiers

extension UTType {
    static let harcPairingInvitation = UTType(
        exportedAs: PairingInvitationFileV1.contentTypeIdentifier,
        conformingTo: .data
    )
}

enum HarcPairingInvitationDocument {
    /// Creates the concrete file handed to macOS sharing services. Keeping
    /// this separate from `save` matters: sharing a `String` causes Mail and
    /// Messages to insert the bearer URI into their body instead of attaching
    /// an importable `.harcpair` document.
    static func makeTemporaryShareFile(
        pairingURI: String,
        now: Date = Date(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard temporaryRoot.isFileURL else {
            throw HarcPairingInvitationDocumentError.unsafeFile
        }
        let directory = temporaryRoot.appendingPathComponent(
            "HarcPairingInvitation-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory
                .appendingPathComponent(
                    "Harc Pairing Invite",
                    isDirectory: false
                )
                .appendingPathExtension(
                    PairingInvitationFileV1.filenameExtension
                )
            try save(pairingURI: pairingURI, to: file, now: now)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func save(
        pairingURI: String,
        to url: URL,
        now: Date = Date()
    ) throws {
        guard url.isFileURL else {
            throw HarcPairingInvitationDocumentError.unsafeFile
        }
        let exactBytes = try PairingInvitationFileV1.encode(
            pairingURI: pairingURI,
            atUnixMilliseconds: try unixMilliseconds(now)
        )
        try exactBytes.write(to: url, options: [.atomic])
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // A pairing invitation is a bearer secret. If Harc cannot restrict
            // the explicit export to the current user, fail closed and remove
            // the just-written file instead of leaving a broadly readable copy.
            try? FileManager.default.removeItem(at: url)
            throw HarcPairingInvitationDocumentError.couldNotProtectFile
        }
    }

    static func load(
        from url: URL,
        now: Date = Date()
    ) throws -> String {
        guard url.isFileURL else {
            throw HarcPairingInvitationDocumentError.unsafeFile
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw HarcPairingInvitationDocumentError.unsafeFile
            }
            throw HarcPairingInvitationDocumentError.unreadableFile
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size > 0,
              information.st_size <= PairingInvitationFileV1.maximumByteCount
        else {
            throw HarcPairingInvitationDocumentError.unsafeFile
        }
        var bytes = Data(
            repeating: 0,
            count: Int(information.st_size)
        )
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count == bytes.count else {
            throw HarcPairingInvitationDocumentError.unreadableFile
        }
        return try PairingInvitationFileV1.decodeURI(
            bytes,
            atUnixMilliseconds: try unixMilliseconds(now)
        )
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= 0,
              value <= Double(UInt64.max) else {
            throw HarcPairingInvitationDocumentError.invalidClock
        }
        return UInt64(value.rounded(.down))
    }
}

enum HarcPairingInvitationDocumentError: LocalizedError, Equatable {
    case couldNotProtectFile
    case invalidClock
    case unsafeFile
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .couldNotProtectFile:
            "The pairing invitation could not be protected for this user."
        case .invalidClock:
            "The system clock cannot validate this pairing invitation."
        case .unsafeFile:
            "The selected file is not a bounded Harc pairing invitation."
        case .unreadableFile:
            "The pairing invitation could not be read."
        }
    }
}
