import Darwin
import Foundation

/// Lifetime-retained descriptor chain for `stagingRoot/objects`.
///
/// Staging is intentionally independent from canonical publication layout, but
/// uses the same security rule: every descendant operation is relative to a
/// trusted directory descriptor and the complete opened hierarchy is checked
/// before and after I/O. A renamed or symlink-replaced ancestor therefore
/// fails closed instead of redirecting an upload or reap into another tree.
final class HostStagingDirectory: @unchecked Sendable {
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
    }

    let rootURL: URL
    private let components: [Component]
    private let rootOffset: Int

    private var rootDescriptor: Int32 { components[rootOffset].descriptor }
    private var objectsDescriptor: Int32 { components[components.count - 1].descriptor }

    init(root requestedRoot: URL) throws {
        guard requestedRoot.isFileURL,
              requestedRoot.path.hasPrefix("/"),
              !requestedRoot.path.contains("\0")
        else { throw HarcHostError.unsafeStagingRoot }

        let standardizedRoot = requestedRoot.standardizedFileURL
        var requestedInformation = stat()
        guard lstat(standardizedRoot.path, &requestedInformation) == 0,
              (requestedInformation.st_mode & S_IFMT) == S_IFDIR
        else { throw HarcHostError.unsafeStagingRoot }

        // `/var` is a system symlink on macOS, and Foundation does not reliably
        // resolve it on every supported runtime. Walk the requested components
        // directly and permit only the narrowly trusted system-link form used
        // by canonical publication: a root-owned link beneath a root-owned,
        // non-writable parent. Both link and target identities remain pinned.
        let names = Array(standardizedRoot.pathComponents.dropFirst())
        guard !names.isEmpty, names.allSatisfy(Self.isSafeComponent) else {
            throw HarcHostError.unsafeStagingRoot
        }

        var opened: [Component] = []
        do {
            let slashDescriptor = open(
                "/",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard slashDescriptor >= 0 else { throw Self.rootIO("open filesystem root") }
            let slashIdentity = try Self.directoryIdentity(
                slashDescriptor,
                requireCurrentUserOwnership: false
            )
            opened.append(
                Component(
                    nameInParent: nil,
                    descriptor: slashDescriptor,
                    targetIdentity: slashIdentity,
                    entryIdentity: slashIdentity,
                    isTrustedSystemSymlink: false,
                    requiresCurrentUserOwnership: false
                )
            )

            for (offset, name) in names.enumerated() {
                opened.append(
                    try Self.openChildDirectory(
                        named: name,
                        relativeTo: opened[opened.count - 1].descriptor,
                        create: false,
                        allowTrustedSystemSymlink: offset != names.count - 1,
                        requireCurrentUserOwnership: offset == names.count - 1
                    )
                )
            }
            rootOffset = opened.count - 1
            opened.append(
                try Self.openChildDirectory(
                    named: "objects",
                    relativeTo: opened[opened.count - 1].descriptor,
                    create: true,
                    allowTrustedSystemSymlink: false,
                    requireCurrentUserOwnership: true
                )
            )
            rootURL = standardizedRoot
            components = opened
            try validateHierarchy()
        } catch {
            for component in opened.reversed() {
                _ = Darwin.close(component.descriptor)
            }
            throw error
        }
    }

    deinit {
        for component in components.reversed() {
            _ = Darwin.close(component.descriptor)
        }
    }

    func validate() throws {
        try validateHierarchy()
    }

    static func objectName(forGeneratedRelativePath relativePath: String) throws -> String {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0")
        else { throw HarcHostError.unsafeStagingPath }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components[0] == "objects",
              components[1].hasSuffix(".chunk"),
              components[1] != ".",
              components[1] != "..",
              UUID(
                uuidString: String(components[1].dropLast(".chunk".count))
              ) != nil
        else { throw HarcHostError.unsafeStagingPath }
        return String(components[1])
    }

    func createExclusiveObject(named name: String) throws -> Int32 {
        try validateHierarchy()
        try Self.requireSafeObjectName(name)
        let descriptor = openat(
            objectsDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw HarcHostError.unsafeStagingPath }
            throw Self.objectIO("create staging object")
        }
        do {
            try validateOpenObject(descriptor, named: name)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func openExistingObject(named name: String, writable: Bool) throws -> Int32 {
        try validateHierarchy()
        try Self.requireSafeObjectName(name)
        let descriptor = openat(
            objectsDescriptor,
            name,
            (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw HarcHostError.unsafeStagingPath }
            if errno == ELOOP { throw HarcHostError.unsafeStagingPath }
            throw Self.objectIO("open staging object")
        }
        do {
            try validateOpenObject(descriptor, named: name)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func validateOpenObject(_ descriptor: Int32, named name: String) throws {
        try validateHierarchy()
        try Self.requireSafeObjectName(name)
        var openedInformation = stat()
        guard fstat(descriptor, &openedInformation) == 0 else {
            throw Self.objectIO("inspect open staging object")
        }
        try Self.validateOwnedRegularFile(openedInformation)

        var namedInformation = stat()
        guard fstatat(
            objectsDescriptor,
            name,
            &namedInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else { throw HarcHostError.unsafeStagingPath }
        try Self.validateOwnedRegularFile(namedInformation)
        guard Identity(openedInformation).matches(namedInformation) else {
            throw HarcHostError.unsafeStagingPath
        }
        try validateHierarchy()
    }

    func objectEntryIsPresent(named name: String) throws -> Bool {
        try validateHierarchy()
        try Self.requireSafeObjectName(name)
        var information = stat()
        guard fstatat(objectsDescriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw Self.objectIO("inspect staging object entry")
        }
        try validateHierarchy()
        return true
    }

    /// Removes a symlink entry without following it, or an exact safe regular
    /// file. Multi-link regular files are rejected so staging never mutates an
    /// inode that is also reachable outside the generated namespace.
    func removeGeneratedEntryIfPresent(named name: String) throws {
        try validateHierarchy()
        try Self.requireSafeObjectName(name)
        var information = stat()
        guard fstatat(objectsDescriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw Self.objectIO("inspect stale staging entry")
        }

        if (information.st_mode & S_IFMT) == S_IFLNK {
            guard unlinkat(objectsDescriptor, name, 0) == 0 else {
                throw Self.objectIO("remove staging symlink")
            }
        } else {
            try Self.validateOwnedRegularFile(information)
            let descriptor = try openExistingObject(named: name, writable: false)
            defer { _ = Darwin.close(descriptor) }
            try validateOpenObject(descriptor, named: name)
            guard unlinkat(objectsDescriptor, name, 0) == 0 else {
                throw Self.objectIO("remove staging object")
            }
        }
        try synchronizeObjects()
        try validateHierarchy()
    }

    func generatedObjectNames() throws -> [String] {
        try validateHierarchy()
        // `dup` would share the retained directory descriptor's seek offset,
        // causing a later enumeration to begin at EOF. Open `.` relative to the
        // retained objects descriptor to obtain an independent open file
        // description with its own offset.
        let enumerationDescriptor = openat(
            objectsDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else {
            throw Self.objectIO("open staging directory for enumeration")
        }
        do {
            var information = stat()
            guard fstat(enumerationDescriptor, &information) == 0,
                  components[components.count - 1].targetIdentity.matches(information)
            else { throw HarcHostError.unsafeStagingRoot }
            try Self.validateOwnedDirectory(information)
            try validateHierarchy()
        } catch {
            _ = Darwin.close(enumerationDescriptor)
            throw error
        }
        guard let directory = fdopendir(enumerationDescriptor) else {
            _ = Darwin.close(enumerationDescriptor)
            throw Self.objectIO("enumerate staging directory")
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        try validateHierarchy()
        return names
    }

    func synchronizeRoot() throws {
        try validateHierarchy()
        guard fsync(rootDescriptor) == 0 else {
            throw Self.rootIO("synchronize staging root")
        }
        try validateHierarchy()
    }

    func synchronizeObjects() throws {
        try validateHierarchy()
        guard fsync(objectsDescriptor) == 0 else {
            throw Self.objectIO("synchronize staging objects directory")
        }
        try validateHierarchy()
    }

    private func validateHierarchy() throws {
        for (offset, component) in components.enumerated() {
            var openedInformation = stat()
            guard fstat(component.descriptor, &openedInformation) == 0,
                  (openedInformation.st_mode & S_IFMT) == S_IFDIR,
                  component.targetIdentity.matches(openedInformation)
            else { throw HarcHostError.unsafeStagingRoot }
            if component.requiresCurrentUserOwnership {
                try Self.validateOwnedDirectory(openedInformation)
            }
            guard offset > 0 else { continue }
            guard let name = component.nameInParent else {
                throw HarcHostError.unsafeStagingRoot
            }
            var namedInformation = stat()
            guard fstatat(
                components[offset - 1].descriptor,
                name,
                &namedInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                component.entryIdentity.matches(namedInformation)
            else { throw HarcHostError.unsafeStagingRoot }
            if component.isTrustedSystemSymlink {
                try Self.validateTrustedSystemSymlink(
                    namedInformation,
                    relativeTo: components[offset - 1].descriptor
                )
            } else {
                guard (namedInformation.st_mode & S_IFMT) == S_IFDIR,
                      component.targetIdentity.matches(namedInformation)
                else { throw HarcHostError.unsafeStagingRoot }
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
        guard isSafeComponent(name) else { throw HarcHostError.unsafeStagingRoot }

        var entryInformation = stat()
        if fstatat(parentDescriptor, name, &entryInformation, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT, create else {
                if errno == ELOOP || errno == ENOTDIR {
                    throw HarcHostError.unsafeStagingRoot
                }
                throw rootIO("inspect staging directory")
            }
            let created = mkdirat(parentDescriptor, name, S_IRWXU) == 0
            guard created || errno == EEXIST else {
                throw rootIO("create staging objects directory")
            }
            if created, fsync(parentDescriptor) != 0 {
                throw rootIO("synchronize staging parent directory")
            }
            guard fstatat(
                parentDescriptor,
                name,
                &entryInformation,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else { throw rootIO("inspect staging directory") }
        }

        let entryType = entryInformation.st_mode & S_IFMT
        let isTrustedSystemSymlink = entryType == S_IFLNK
        if isTrustedSystemSymlink {
            guard allowTrustedSystemSymlink else {
                throw HarcHostError.unsafeStagingRoot
            }
            try validateTrustedSystemSymlink(
                entryInformation,
                relativeTo: parentDescriptor
            )
        } else {
            guard entryType == S_IFDIR else { throw HarcHostError.unsafeStagingRoot }
        }

        let noFollowFlag: Int32 = isTrustedSystemSymlink ? 0 : O_NOFOLLOW
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | noFollowFlag | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw HarcHostError.unsafeStagingRoot
            }
            throw rootIO("open staging directory")
        }
        do {
            let targetIdentity = try directoryIdentity(
                descriptor,
                requireCurrentUserOwnership: requireCurrentUserOwnership
            )
            if isTrustedSystemSymlink {
                guard targetIdentity.owner == 0 else {
                    throw HarcHostError.unsafeStagingRoot
                }
            } else {
                guard targetIdentity.matches(entryInformation) else {
                    throw HarcHostError.unsafeStagingRoot
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
            else { throw HarcHostError.unsafeStagingRoot }
            return Component(
                nameInParent: name,
                descriptor: descriptor,
                targetIdentity: targetIdentity,
                entryIdentity: Identity(entryInformation),
                isTrustedSystemSymlink: isTrustedSystemSymlink,
                requiresCurrentUserOwnership: requireCurrentUserOwnership
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func directoryIdentity(
        _ descriptor: Int32,
        requireCurrentUserOwnership: Bool
    ) throws -> Identity {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR
        else { throw HarcHostError.unsafeStagingRoot }
        if requireCurrentUserOwnership {
            try validateOwnedDirectory(information)
        }
        return Identity(information)
    }

    private static func validateOwnedDirectory(_ information: stat) throws {
        guard information.st_uid == geteuid(),
              (information.st_mode & 0o022) == 0
        else { throw HarcHostError.unsafeStagingRoot }
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
        else { throw HarcHostError.unsafeStagingRoot }
    }

    private static func validateOwnedRegularFile(_ information: stat) throws {
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              (information.st_mode & 0o022) == 0
        else { throw HarcHostError.unsafeStagingPath }
    }

    private static func requireSafeObjectName(_ name: String) throws {
        guard name.hasSuffix(".chunk"),
              UUID(uuidString: String(name.dropLast(".chunk".count))) != nil,
              isSafeComponent(name)
        else { throw HarcHostError.unsafeStagingPath }
    }

    private static func isSafeComponent<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private static func rootIO(_ operation: String) -> HarcHostError {
        .stagingIO("Could not \(operation): errno \(errno).")
    }

    private static func objectIO(_ operation: String) -> HarcHostError {
        .stagingIO("Could not \(operation): errno \(errno).")
    }
}
