import Darwin
import Foundation
import HarcDomain

/// A descriptor-retained canonical publication directory. Every component is
/// opened relative to its already-trusted parent with `O_NOFOLLOW`. The only
/// exception is a root-owned symlink beneath a root-owned, non-writable parent
/// (for macOS system aliases such as `/var`); both the link and opened target
/// identities are retained. Operations revalidate the complete chain before
/// touching a child entry, so an ancestor replacement cannot redirect I/O.
final class HostCanonicalDirectory: @unchecked Sendable {
    private struct Identity: Sendable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
            owner = information.st_uid
            mode = information.st_mode
        }

        func matches(_ information: stat) -> Bool {
            device == information.st_dev
                && inode == information.st_ino
                && owner == information.st_uid
                && (mode & (S_IFMT | 0o7777))
                    == (information.st_mode & (S_IFMT | 0o7777))
        }
    }

    private struct Component: Sendable {
        let nameInParent: String?
        let descriptor: Int32
        let targetIdentity: Identity
        let entryIdentity: Identity
        let isTrustedSystemSymlink: Bool
        let requiresCurrentUserOwnership: Bool
        let ownsDescriptor: Bool

        func borrowed() -> Self {
            Self(
                nameInParent: nameInParent,
                descriptor: descriptor,
                targetIdentity: targetIdentity,
                entryIdentity: entryIdentity,
                isTrustedSystemSymlink: isTrustedSystemSymlink,
                requiresCurrentUserOwnership: requiresCurrentUserOwnership,
                ownsDescriptor: false
            )
        }
    }

    private let components: [Component]
    /// Keeps the process-lifetime root descriptors alive while a dated child
    /// directory borrows them. The root anchor itself has no retained anchor.
    private let retainedRootAnchor: HostCanonicalRootAnchor?

    var descriptor: Int32 {
        components[components.count - 1].descriptor
    }

    fileprivate init(root: URL) throws {
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              !root.path.contains("\0")
        else { throw HarcHostError.unsafePublicationRoot }

        let rootComponents = root.standardizedFileURL.pathComponents.dropFirst()
        guard !rootComponents.isEmpty,
              rootComponents.allSatisfy(Self.isSafeDirectoryComponent)
        else { throw HarcHostError.unsafePublicationRoot }

        var opened: [Component] = []
        do {
            let slashDescriptor = open(
                "/",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard slashDescriptor >= 0 else {
                throw Self.directoryIO("Could not open the filesystem root")
            }
            let slashIdentity = try Self.validatedDirectoryIdentity(
                descriptor: slashDescriptor,
                requireCurrentUserOwnership: false
            )
            opened.append(
                Component(
                    nameInParent: nil,
                    descriptor: slashDescriptor,
                    targetIdentity: slashIdentity,
                    entryIdentity: slashIdentity,
                    isTrustedSystemSymlink: false,
                    requiresCurrentUserOwnership: false,
                    ownsDescriptor: true
                )
            )

            for (offset, name) in rootComponents.enumerated() {
                let isPublicationRoot = offset == rootComponents.count - 1
                opened.append(
                    try Self.openChildDirectory(
                        named: name,
                        relativeTo: opened[opened.count - 1].descriptor,
                        create: isPublicationRoot,
                        allowTrustedSystemSymlink: !isPublicationRoot,
                        requireCurrentUserOwnership: isPublicationRoot
                    )
                )
            }
            components = opened
            retainedRootAnchor = nil
            try validateHierarchy()
        } catch {
            for component in opened.reversed() where component.ownsDescriptor {
                _ = Darwin.close(component.descriptor)
            }
            throw error
        }
    }

    init(rootAnchor: HostCanonicalRootAnchor, year: String, day: String) throws {
        try rootAnchor.validateRetainedIdentity()
        var opened = rootAnchor.retainedRoot.components.map { $0.borrowed() }
        let borrowedCount = opened.count
        do {
            opened.append(
                try Self.openChildDirectory(
                    named: year,
                    relativeTo: opened[opened.count - 1].descriptor,
                    create: true,
                    allowTrustedSystemSymlink: false,
                    requireCurrentUserOwnership: true
                )
            )
            opened.append(
                try Self.openChildDirectory(
                    named: day,
                    relativeTo: opened[opened.count - 1].descriptor,
                    create: true,
                    allowTrustedSystemSymlink: false,
                    requireCurrentUserOwnership: true
                )
            )
            components = opened
            retainedRootAnchor = rootAnchor
            try validateHierarchy()
        } catch {
            for component in opened.dropFirst(borrowedCount).reversed()
                where component.ownsDescriptor
            {
                _ = Darwin.close(component.descriptor)
            }
            throw error
        }
    }

    deinit {
        for component in components.reversed() where component.ownsDescriptor {
            _ = Darwin.close(component.descriptor)
        }
    }

    func entryExists(named name: String) throws -> Bool {
        try validateHierarchy()
        try Self.requireSafeChildName(name)
        var information = stat()
        guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw Self.entryIO("Could not inspect a canonical artifact")
        }
        try Self.validateOwnedRegularFile(information)
        try validateHierarchy()
        return true
    }

    func createExclusiveFile(
        named name: String,
        flags: Int32 = O_WRONLY,
        permissions: mode_t = S_IRUSR | S_IWUSR
    ) throws -> Int32 {
        try validateHierarchy()
        try Self.requireSafeChildName(name)
        let fileDescriptor = openat(
            descriptor,
            name,
            flags | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard fileDescriptor >= 0 else {
            if errno == ELOOP { throw HarcHostError.unsafePublicationPath }
            throw Self.entryIO("Could not create a canonical artifact")
        }
        do {
            try validateOpenFile(fileDescriptor, named: name)
            return fileDescriptor
        } catch {
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    func openExistingRegularFile(named name: String) throws -> Int32 {
        try validateHierarchy()
        try Self.requireSafeChildName(name)
        let fileDescriptor = openat(
            descriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            if errno == ELOOP { throw HarcHostError.unsafePublicationPath }
            throw Self.entryIO("Could not open a canonical artifact")
        }
        do {
            try validateOpenFile(fileDescriptor, named: name)
            return fileDescriptor
        } catch {
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    func validateOpenFile(_ fileDescriptor: Int32, named name: String) throws {
        try validateHierarchy()
        try Self.requireSafeChildName(name)
        var openedInformation = stat()
        guard fstat(fileDescriptor, &openedInformation) == 0 else {
            throw Self.entryIO("Could not inspect an open canonical artifact")
        }
        try Self.validateOwnedRegularFile(openedInformation)

        var namedInformation = stat()
        guard fstatat(descriptor, name, &namedInformation, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw HarcHostError.unsafePublicationPath
        }
        try Self.validateOwnedRegularFile(namedInformation)
        guard Identity(openedInformation).matches(namedInformation) else {
            throw HarcHostError.unsafePublicationPath
        }
        try validateHierarchy()
    }

    func removeOwnedRegularFileIfPresent(named name: String) throws {
        try validateHierarchy()
        try Self.requireSafeChildName(name)
        let fileDescriptor = openat(
            descriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            if errno == ENOENT { return }
            if errno == ELOOP { throw HarcHostError.unsafePublicationPath }
            throw Self.entryIO("Could not open a stale canonical artifact")
        }
        defer { _ = Darwin.close(fileDescriptor) }
        try removeFile(named: name, matching: fileDescriptor)
    }

    func removeFile(named name: String, matching fileDescriptor: Int32) throws {
        try validateOpenFile(fileDescriptor, named: name)
        guard unlinkat(descriptor, name, 0) == 0 else {
            throw Self.entryIO("Could not remove a canonical artifact")
        }
        try validateHierarchy()
    }

    func renameExclusively(from sourceName: String, to destinationName: String) throws {
        try validateHierarchy()
        try Self.requireSafeChildName(sourceName)
        try Self.requireSafeChildName(destinationName)
        let sourceDescriptor = try openExistingRegularFile(named: sourceName)
        defer { _ = Darwin.close(sourceDescriptor) }

        guard renameatx_np(
            descriptor,
            sourceName,
            descriptor,
            destinationName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw HarcHostError.canonicalDestinationExists }
            throw Self.entryIO("Could not atomically publish a canonical artifact")
        }

        // Prove the destination still names the exact regular file opened above,
        // and that no symlink/ancestor replacement redirected the operation.
        try validateOpenFile(sourceDescriptor, named: destinationName)
        var sourceInformation = stat()
        guard fstatat(descriptor, sourceName, &sourceInformation, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT
        else { throw HarcHostError.unsafePublicationPath }
    }

    func synchronize() throws {
        try validateHierarchy()
        guard fsync(descriptor) == 0 else {
            throw Self.directoryIO("Could not synchronize the canonical directory")
        }
        try validateHierarchy()
    }

    fileprivate func validateRetainedIdentity() throws {
        try validateHierarchy()
    }

    private func validateHierarchy() throws {
        for (offset, component) in components.enumerated() {
            var openedInformation = stat()
            guard fstat(component.descriptor, &openedInformation) == 0,
                  (openedInformation.st_mode & S_IFMT) == S_IFDIR,
                  component.targetIdentity.matches(openedInformation)
            else { throw HarcHostError.unsafePublicationRoot }
            if component.requiresCurrentUserOwnership {
                try Self.validateOwnedDirectory(openedInformation)
            }
            guard offset > 0 else { continue }

            let parent = components[offset - 1]
            guard let name = component.nameInParent else {
                throw HarcHostError.unsafePublicationRoot
            }
            var namedInformation = stat()
            guard fstatat(
                parent.descriptor,
                name,
                &namedInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                component.entryIdentity.matches(namedInformation)
            else { throw HarcHostError.unsafePublicationRoot }
            if component.isTrustedSystemSymlink {
                try Self.validateTrustedSystemSymlink(
                    namedInformation,
                    relativeTo: parent.descriptor
                )
            } else {
                guard (namedInformation.st_mode & S_IFMT) == S_IFDIR,
                      component.targetIdentity.matches(namedInformation)
                else { throw HarcHostError.unsafePublicationRoot }
            }
        }
    }

    private static func openChildDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32,
        create: Bool,
        allowTrustedSystemSymlink: Bool,
        requireCurrentUserOwnership: Bool
    ) throws -> Component {
        guard isSafeDirectoryComponent(name) else {
            throw HarcHostError.unsafePublicationRoot
        }

        var entryInformation = stat()
        if fstatat(parentDescriptor, name, &entryInformation, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, create else {
                if errno == ELOOP || errno == ENOTDIR {
                    throw HarcHostError.unsafePublicationRoot
                }
                throw directoryIO("Could not inspect a host canonical directory")
            }
            let created = mkdirat(parentDescriptor, name, S_IRWXU) == 0
            guard created || errno == EEXIST else {
                throw directoryIO("Could not create a host canonical directory")
            }
            if created {
                // The parent directory entry must be durable before any later
                // checkpoint can rely on a descendant artifact.
                guard fsync(parentDescriptor) == 0 else {
                    throw directoryIO("Could not synchronize a host canonical parent directory")
                }
            }
            guard fstatat(
                parentDescriptor,
                name,
                &entryInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw directoryIO("Could not inspect a host canonical directory")
            }
        }

        let entryType = entryInformation.st_mode & S_IFMT
        let isTrustedSystemSymlink = entryType == S_IFLNK
        if isTrustedSystemSymlink {
            guard allowTrustedSystemSymlink else {
                throw HarcHostError.unsafePublicationRoot
            }
            try validateTrustedSystemSymlink(
                entryInformation,
                relativeTo: parentDescriptor
            )
        } else {
            guard entryType == S_IFDIR else {
                throw HarcHostError.unsafePublicationRoot
            }
        }

        let noFollowFlag: Int32 = isTrustedSystemSymlink ? 0 : O_NOFOLLOW
        let fileDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | noFollowFlag | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw HarcHostError.unsafePublicationRoot
            }
            throw directoryIO("Could not open a host canonical directory")
        }
        do {
            let targetIdentity = try validatedDirectoryIdentity(
                descriptor: fileDescriptor,
                requireCurrentUserOwnership: requireCurrentUserOwnership
            )
            if isTrustedSystemSymlink {
                guard targetIdentity.owner == 0 else {
                    throw HarcHostError.unsafePublicationRoot
                }
            } else {
                guard targetIdentity.matches(entryInformation) else {
                    throw HarcHostError.unsafePublicationRoot
                }
            }
            var currentEntryInformation = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &currentEntryInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                Identity(entryInformation).matches(currentEntryInformation)
            else { throw HarcHostError.unsafePublicationRoot }
            return Component(
                nameInParent: name,
                descriptor: fileDescriptor,
                targetIdentity: targetIdentity,
                entryIdentity: Identity(entryInformation),
                isTrustedSystemSymlink: isTrustedSystemSymlink,
                requiresCurrentUserOwnership: requireCurrentUserOwnership,
                ownsDescriptor: true
            )
        } catch {
            _ = Darwin.close(fileDescriptor)
            throw error
        }
    }

    private static func validatedDirectoryIdentity(
        descriptor: Int32,
        requireCurrentUserOwnership: Bool
    ) throws -> Identity {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR
        else { throw HarcHostError.unsafePublicationRoot }
        if requireCurrentUserOwnership {
            try validateOwnedDirectory(information)
        }
        return Identity(information)
    }

    private static func validateOwnedDirectory(_ information: stat) throws {
        guard information.st_uid == geteuid(),
              (information.st_mode & 0o022) == 0
        else { throw HarcHostError.unsafePublicationRoot }
    }

    private static func validateTrustedSystemSymlink(
        _ information: stat,
        relativeTo parentDescriptor: Int32
    ) throws {
        var parentInformation = stat()
        guard (information.st_mode & S_IFMT) == S_IFLNK,
              information.st_uid == 0,
              fstat(parentDescriptor, &parentInformation) == 0,
              (parentInformation.st_mode & S_IFMT) == S_IFDIR,
              parentInformation.st_uid == 0,
              (parentInformation.st_mode & 0o022) == 0
        else { throw HarcHostError.unsafePublicationRoot }
    }

    private static func validateOwnedRegularFile(_ information: stat) throws {
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              (information.st_mode & 0o022) == 0
        else { throw HarcHostError.unsafePublicationPath }
    }

    private static func isSafeDirectoryComponent<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func requireSafeChildName(_ value: String) throws {
        guard isSafeDirectoryComponent(value) else {
            throw HarcHostError.unsafePublicationPath
        }
    }

    private static func directoryIO(_ context: String) -> HarcHostError {
        .publicationIO("\(context): errno \(errno).")
    }

    private static func entryIO(_ context: String) -> HarcHostError {
        .publicationIO("\(context): errno \(errno).")
    }
}

/// Process-lifetime anchor for the configured canonical root. Child
/// publication directories borrow this exact descriptor chain, and every
/// operation revalidates that the configured root pathname still names the
/// retained inode. Renaming the root aside therefore fails closed instead of
/// silently continuing inside a detached tree.
final class HostCanonicalRootAnchor: @unchecked Sendable {
    let root: URL
    fileprivate let retainedRoot: HostCanonicalDirectory

    init(root requestedRoot: URL) throws {
        let root = requestedRoot.standardizedFileURL
        guard root.isFileURL,
              root.path != "/",
              !root.lastPathComponent.isEmpty,
              root.path == requestedRoot.path
        else { throw HarcHostError.unsafePublicationRoot }
        self.root = root
        retainedRoot = try HostCanonicalDirectory(root: root)
        try retainedRoot.validateRetainedIdentity()
    }

    func validateRetainedIdentity() throws {
        try retainedRoot.validateRetainedIdentity()
    }
}

struct HostCanonicalPublicationPaths: Equatable, Sendable {
    let root: URL
    let directory: URL
    let relativeWAVPath: String
    let wavURL: URL
    let manifestSidecarURL: URL
    let receiptSidecarURL: URL
    let temporaryURL: URL

    private let trustedDirectory: HostCanonicalDirectory

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root
            && lhs.directory == rhs.directory
            && lhs.relativeWAVPath == rhs.relativeWAVPath
            && lhs.wavURL == rhs.wavURL
            && lhs.manifestSidecarURL == rhs.manifestSidecarURL
            && lhs.receiptSidecarURL == rhs.receiptSidecarURL
            && lhs.temporaryURL == rhs.temporaryURL
    }

    static func make(
        root: URL,
        captureStartedAt: Date,
        canonicalRecordingID: CanonicalRecordingID,
        temporaryName: String
    ) throws -> Self {
        try make(
            rootAnchor: HostCanonicalRootAnchor(root: root),
            captureStartedAt: captureStartedAt,
            canonicalRecordingID: canonicalRecordingID,
            temporaryName: temporaryName
        )
    }

    static func make(
        rootAnchor: HostCanonicalRootAnchor,
        captureStartedAt: Date,
        canonicalRecordingID: CanonicalRecordingID,
        temporaryName: String
    ) throws -> Self {
        guard captureStartedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.unsafePublicationPath
        }
        let components = try pathComponents(
            captureStartedAt: captureStartedAt,
            canonicalRecordingID: canonicalRecordingID
        )
        return try make(
            rootAnchor: rootAnchor,
            canonicalRecordingID: canonicalRecordingID,
            persistedRelativeWAVPath: components.relativeWAVPath,
            temporaryName: temporaryName
        )
    }

    /// Recovery must use the once-persisted relative path. Recomputing its day
    /// from `captureStartedAt` would make a host time-zone change strand a
    /// safely published recording.
    static func make(
        root: URL,
        canonicalRecordingID: CanonicalRecordingID,
        persistedRelativeWAVPath: String,
        temporaryName: String
    ) throws -> Self {
        try make(
            rootAnchor: HostCanonicalRootAnchor(root: root),
            canonicalRecordingID: canonicalRecordingID,
            persistedRelativeWAVPath: persistedRelativeWAVPath,
            temporaryName: temporaryName
        )
    }

    static func make(
        rootAnchor: HostCanonicalRootAnchor,
        canonicalRecordingID: CanonicalRecordingID,
        persistedRelativeWAVPath: String,
        temporaryName: String
    ) throws -> Self {
        guard isSafeTemporaryName(temporaryName) else {
            throw HarcHostError.unsafePublicationPath
        }
        let components = try validatedPersistedPathComponents(
            persistedRelativeWAVPath,
            canonicalRecordingID: canonicalRecordingID
        )
        try rootAnchor.validateRetainedIdentity()
        let root = rootAnchor.root
        let yearDirectory = root.appendingPathComponent(components.year, isDirectory: true)
        let directory = yearDirectory.appendingPathComponent(components.day, isDirectory: true)
        let trustedDirectory = try HostCanonicalDirectory(
            rootAnchor: rootAnchor,
            year: components.year,
            day: components.day
        )

        let wavURL = directory.appendingPathComponent(components.wavName)
        let stem = canonicalRecordingID.description.lowercased()
        let manifestURL = directory.appendingPathComponent(stem).appendingPathExtension("harc-manifest")
        let receiptURL = directory.appendingPathComponent(stem).appendingPathExtension("harc-receipt")
        let temporaryURL = directory.appendingPathComponent(temporaryName)

        return Self(
            root: root,
            directory: directory,
            relativeWAVPath: persistedRelativeWAVPath,
            wavURL: wavURL,
            manifestSidecarURL: manifestURL,
            receiptSidecarURL: receiptURL,
            temporaryURL: temporaryURL,
            trustedDirectory: trustedDirectory
        )
    }

    func entryExists(at url: URL) throws -> Bool {
        try trustedDirectory.entryExists(named: childName(for: url))
    }

    func createExclusiveFile(at url: URL) throws -> Int32 {
        try trustedDirectory.createExclusiveFile(named: childName(for: url))
    }

    func openExistingRegularFile(at url: URL) throws -> Int32 {
        try trustedDirectory.openExistingRegularFile(named: childName(for: url))
    }

    func validateOpenFile(_ descriptor: Int32, at url: URL) throws {
        try trustedDirectory.validateOpenFile(descriptor, named: childName(for: url))
    }

    func removeOwnedRegularFileIfPresent(at url: URL) throws {
        try trustedDirectory.removeOwnedRegularFileIfPresent(named: childName(for: url))
    }

    func removeFile(at url: URL, matching descriptor: Int32) throws {
        try trustedDirectory.removeFile(named: childName(for: url), matching: descriptor)
    }

    func renameExclusively(from source: URL, to destination: URL) throws {
        try trustedDirectory.renameExclusively(
            from: childName(for: source),
            to: childName(for: destination)
        )
    }

    func synchronizeDirectory() throws {
        try trustedDirectory.synchronize()
    }

    static func validatePersistedRelativeWAVPath(
        _ relativePath: String,
        canonicalRecordingID: CanonicalRecordingID
    ) throws {
        _ = try validatedPersistedPathComponents(
            relativePath,
            canonicalRecordingID: canonicalRecordingID
        )
    }

    static func relativeWAVPath(
        captureStartedAt: Date,
        canonicalRecordingID: CanonicalRecordingID
    ) throws -> String {
        try pathComponents(
            captureStartedAt: captureStartedAt,
            canonicalRecordingID: canonicalRecordingID
        ).relativeWAVPath
    }

    private func childName(for url: URL) throws -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let name = url.lastPathComponent
        guard parent == directory.standardizedFileURL,
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0")
        else { throw HarcHostError.unsafePublicationPath }
        return name
    }

    private static func pathComponents(
        captureStartedAt: Date,
        canonicalRecordingID: CanonicalRecordingID
    ) throws -> (year: String, day: String, stem: String, relativeWAVPath: String) {
        guard captureStartedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HarcHostError.unsafePublicationPath
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = String(format: "%04d", calendar.component(.year, from: captureStartedAt))
        let month = String(format: "%02d", calendar.component(.month, from: captureStartedAt))
        let dayOfMonth = String(format: "%02d", calendar.component(.day, from: captureStartedAt))
        let day = "\(year)-\(month)-\(dayOfMonth)"
        let stem = canonicalRecordingID.description.lowercased()
        return (year, day, stem, "\(year)/\(day)/\(stem).wav")
    }

    private static func validatedPersistedPathComponents(
        _ relativePath: String,
        canonicalRecordingID: CanonicalRecordingID
    ) throws -> (year: String, day: String, wavName: String) {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 3 else { throw HarcHostError.unsafePublicationPath }
        let year = components[0]
        let day = components[1]
        let wavName = components[2]
        guard year.utf8.count == 4,
              year.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              day.utf8.count == 10,
              day.hasPrefix("\(year)-"),
              day.utf8.enumerated().allSatisfy({ offset, byte in
                  offset == 4 || offset == 7
                      ? byte == 0x2d
                      : byte >= 0x30 && byte <= 0x39
              }),
              wavName == "\(canonicalRecordingID.description.lowercased()).wav",
              let yearValue = Int(year),
              let monthValue = Int(day.dropFirst(5).prefix(2)),
              let dayValue = Int(day.suffix(2))
        else { throw HarcHostError.unsafePublicationPath }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let values = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: yearValue,
            month: monthValue,
            day: dayValue
        )
        guard let date = calendar.date(from: values) else {
            throw HarcHostError.unsafePublicationPath
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == yearValue,
              roundTrip.month == monthValue,
              roundTrip.day == dayValue
        else { throw HarcHostError.unsafePublicationPath }
        return (year, day, wavName)
    }

    private static func isSafeTemporaryName(_ value: String) -> Bool {
        guard value.hasPrefix(".harc-"), value.hasSuffix(".partial"), value.count <= 96 else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7a)
                || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2d
                || $0 == 0x2e
        }
    }
}
