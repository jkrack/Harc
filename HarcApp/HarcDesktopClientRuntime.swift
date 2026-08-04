import Combine
import CryptoKit
import Darwin
import Foundation
import HarcAudio
import HarcClient
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcTransfer

@MainActor
final class HarcDesktopClientRuntime: ObservableObject {
    @Published private(set) var pendingCaptureCount = 0
    @Published private(set) var statusMessage = "Client storage ready"

    let identity: InstallationSigningIdentity
    let transferStore: HarcTransferStore
    let libraryCache: HarcLibraryCache
    let transferCoordinator: HarcDesktopClientTransferCoordinator
    let pairingCoordinator: HarcDesktopClientPairingCoordinator
    let libraryCoordinator: HarcMobileLibraryCoordinator
    let root: URL
    let routeURL: URL

    private var cancellables = Set<AnyCancellable>()

    private init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        libraryCache: HarcLibraryCache,
        root: URL
    ) throws {
        self.identity = identity
        self.transferStore = transferStore
        self.libraryCache = libraryCache
        self.root = root
        let routeURL = root.appendingPathComponent("host-route.json")
        self.routeURL = routeURL
        let transferCoordinator = try HarcDesktopClientTransferCoordinator(
            identity: identity,
            store: transferStore,
            clientRoot: root,
            routeURL: routeURL
        )
        self.transferCoordinator = transferCoordinator
        let libraryCoordinator = HarcMobileLibraryCoordinator(
            identity: identity,
            transferStore: transferStore,
            cache: libraryCache,
            routeURL: routeURL
        )
        self.libraryCoordinator = libraryCoordinator
        pairingCoordinator = HarcDesktopClientPairingCoordinator(
            identity: identity,
            store: transferStore,
            routeURL: routeURL,
            hasActiveAdoption: try transferStore.activeAdoption() != nil
        ) {
            transferCoordinator.retryPending()
            libraryCoordinator.refresh()
        }
        transferCoordinator.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
            .store(in: &cancellables)
        refreshStatus()
    }

    static func start() async throws -> HarcDesktopClientRuntime {
        let root = try clientRoot()
        let locations = try ClientStoreLocations(rootDirectory: root)
        let routeURL = root.appendingPathComponent("host-route.json")
        let hasPriorState = FileManager.default.fileExists(
            atPath: locations.transferDatabase.path
        ) || FileManager.default.fileExists(atPath: routeURL.path)
        let identityManager = InstallationIdentityManager(
            keyStore: KeychainSoftwareInstallationKeyStore(
                service: "com.harc.Harc.desktop-client.installation-identity",
                account: "device-p256-signing-v1"
            )
        )
        let resolution = try await identityManager.resolve(
            evidence: InstallationIdentityEvidence(
                hasPriorIdentityState: hasPriorState,
                hasIdentityBoundCaptures: try hasDurableCaptures(root: root)
            )
        )
        guard case .available(let identity, _) = resolution else {
            throw HarcDesktopClientError.installationIdentityLost
        }
        let transferStore = try HarcTransferStore(
            rootDirectory: root,
            installationDeviceID: identity.deviceID
        )
        let libraryCache = try HarcLibraryCache(rootDirectory: root)
        try recoverCaptureSidecars(
            root: root,
            store: transferStore,
            deviceID: identity.deviceID
        )
        let runtime = try HarcDesktopClientRuntime(
            identity: identity,
            transferStore: transferStore,
            libraryCache: libraryCache,
            root: root
        )
        runtime.transferCoordinator.retryPending()
        runtime.libraryCoordinator.refresh()
        return runtime
    }

    func makeRecordingCommitter() throws -> any RecordingCommitter {
        try HarcDesktopClientRecordingCommitter(
            identity: identity,
            transferStore: transferStore,
            root: root
        ) { [weak self] in
            Task { @MainActor in
                self?.refreshStatus()
                self?.transferCoordinator.retryPending()
            }
        }
    }

    func refreshStatus() {
        do {
            pendingCaptureCount = try transferStore.recordingOutboxes().filter {
                $0.stateMachine.state != .committed
            }.count
            statusMessage = transferCoordinator.statusMessage
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func shutdown() {
        pairingCoordinator.cancel()
        transferCoordinator.shutdown()
        libraryCoordinator.shutdown()
    }

    private static func clientRoot() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw CocoaError(.fileNoSuchFile) }
        let root = support.appendingPathComponent(
            "Harc/ClientState",
            isDirectory: true
        )
        try HarcDesktopClientFiles.requireDirectory(root)
        return root
    }

    private static func hasDurableCaptures(root: URL) throws -> Bool {
        let directory = root.appendingPathComponent(
            "Captures",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).contains { $0.pathExtension == "json" || $0.pathExtension == "wav" }
    }

    private static func recoverCaptureSidecars(
        root: URL,
        store: HarcTransferStore,
        deviceID: DeviceID
    ) throws {
        let directory = root.appendingPathComponent(
            "Captures",
            isDirectory: true
        )
        try HarcDesktopClientFiles.requireDirectory(directory)
        for sidecarURL in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter({ $0.lastPathComponent.hasSuffix(".capture.json") }) {
            let sidecar = try JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: Data(contentsOf: sidecarURL, options: .mappedIfSafe)
            )
            guard sidecar.capture.producingDeviceID == deviceID else {
                throw HarcDesktopClientError.captureIdentityMismatch
            }
            let masterURL = directory.appendingPathComponent(
                "\(sidecar.capture.originRecordingID.recordingUUID.uuidString.lowercased()).wav"
            )
            guard FileManager.default.fileExists(atPath: masterURL.path) else {
                throw HarcDesktopClientError.missingDurableMaster
            }
            _ = try store.persistFinalizedCapture(
                sidecar.capture,
                masterFileURL: masterURL,
                persistedAt: sidecar.persistedAt
            )
        }
    }
}

struct HarcDesktopClientCaptureSidecar: Codable, Sendable {
    let capture: FinalizedCapture
    let transcript: SessionTranscript?
    let persistedAt: Date
}

private struct HarcDesktopClientRecordingCommitter: RecordingCommitter {
    let identity: InstallationSigningIdentity
    let transferStore: HarcTransferStore
    let root: URL
    let onAccepted: @Sendable () -> Void

    init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        root: URL,
        onAccepted: @escaping @Sendable () -> Void
    ) throws {
        self.identity = identity
        self.transferStore = transferStore
        self.root = root
        self.onAccepted = onAccepted
    }

    func commit(_ captured: CapturedRecording) async throws -> RecordingCommitOutcome {
        let origin = identity.originRecordingID()
        let directory = root.appendingPathComponent(
            "Captures",
            isDirectory: true
        )
        try HarcDesktopClientFiles.requireDirectory(directory)
        let finalURL = directory.appendingPathComponent(
            "\(origin.recordingUUID.uuidString.lowercased()).wav"
        )
        let prepared = try HarcDesktopClientFiles.canonicalizeWAV(
            source: captured.localMasterURL,
            destination: finalURL
        )
        let durationNanoseconds = UInt64(
            max(0, captured.endedAt.timeIntervalSince(captured.startedAt))
                * 1_000_000_000
        )
        let capture = try FinalizedCapture(
            producingDeviceID: identity.deviceID,
            originRecordingID: origin,
            captureStartedAt: captured.startedAt,
            captureEndedAt: captured.endedAt,
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: durationNanoseconds,
            finalizationReason: .userStopped,
            totalCanonicalFrames: prepared.frames,
            totalCanonicalBytes: prepared.frames * 2,
            canonicalPCMSHA256: try CanonicalPCMHash(prepared.pcmSHA256),
            discontinuities: []
        )
        var transcript = captured.transcript
        transcript?.audioPath = finalURL.path
        let sidecar = HarcDesktopClientCaptureSidecar(
            capture: capture,
            transcript: transcript,
            persistedAt: Date()
        )
        let sidecarURL = directory.appendingPathComponent(
            "\(origin.recordingUUID.uuidString.lowercased()).capture.json"
        )
        try HarcDesktopClientFiles.writeSidecar(sidecar, to: sidecarURL)
        _ = try transferStore.persistFinalizedCapture(
            capture,
            masterFileURL: finalURL,
            persistedAt: sidecar.persistedAt
        )
        // The canonical ClientState master and sidecar are durable and the
        // outbox transaction owns recovery before the ephemeral capture cache
        // is consumed.
        try? FileManager.default.removeItem(at: captured.localMasterURL)
        onAccepted()
        return .acceptedForDeferredPublication(localMasterURL: finalURL)
    }
}

enum HarcDesktopClientFiles {
    struct PreparedWAV {
        let frames: UInt64
        let pcmSHA256: Data
    }

    static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw HarcDesktopClientError.unsafePath }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    static func canonicalizeWAV(
        source: URL,
        destination: URL
    ) throws -> PreparedWAV {
        guard source.isFileURL, destination.isFileURL else {
            throw HarcDesktopClientError.unsafePath
        }
        try validateOwnedDirectory(destination.deletingLastPathComponent())
        let input = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw HarcDesktopClientError.invalidWAV }
        defer { Darwin.close(input) }
        var statBuffer = stat()
        guard fstat(input, &statBuffer) == 0,
              statBuffer.st_mode & S_IFMT == S_IFREG,
              statBuffer.st_size >= 44 else {
            throw HarcDesktopClientError.invalidWAV
        }
        let headerCount = min(Int(statBuffer.st_size), 64 * 1_024)
        var header = Data(count: headerCount)
        let headerRead = header.withUnsafeMutableBytes {
            pread(input, $0.baseAddress, headerCount, 0)
        }
        guard headerRead == headerCount,
              header.prefix(4) == Data("RIFF".utf8),
              header[8..<12] == Data("WAVE".utf8) else {
            throw HarcDesktopClientError.invalidWAV
        }
        let layout = try wavLayout(header)
        guard layout.dataBytes > 0, layout.dataBytes % 2 == 0,
              UInt64(layout.dataOffset) + UInt64(layout.dataBytes)
                <= UInt64(statBuffer.st_size),
              layout.dataBytes <= Int(UInt32.max) else {
            throw HarcDesktopClientError.invalidWAV
        }

        let output = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard output >= 0 else { throw HarcDesktopClientError.destinationExists }
        var succeeded = false
        defer {
            Darwin.close(output)
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        try writeAll(canonicalHeader(dataBytes: UInt32(layout.dataBytes)), to: output)
        var hasher = SHA256()
        var offset = 0
        while offset < layout.dataBytes {
            let count = min(1 * 1_024 * 1_024, layout.dataBytes - offset)
            var bytes = Data(count: count)
            let readCount = bytes.withUnsafeMutableBytes {
                pread(
                    input,
                    $0.baseAddress,
                    count,
                    off_t(layout.dataOffset + offset)
                )
            }
            guard readCount == count else { throw HarcDesktopClientError.invalidWAV }
            hasher.update(data: bytes)
            try writeAll(bytes, to: output)
            offset += count
        }
        guard fsync(output) == 0 else { throw HarcDesktopClientError.storageFailure }
        succeeded = true
        return PreparedWAV(
            frames: UInt64(layout.dataBytes / 2),
            pcmSHA256: Data(hasher.finalize())
        )
    }

    fileprivate static func writeSidecar(
        _ sidecar: HarcDesktopClientCaptureSidecar,
        to destination: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeProtectedData(encoder.encode(sidecar), to: destination)
    }

    static func writeProtectedData(
        _ data: Data,
        to destination: URL
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        try FileManager.default.moveItem(at: temporary, to: destination)
        let directory = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC
        )
        guard directory >= 0 else { throw HarcDesktopClientError.storageFailure }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else {
            throw HarcDesktopClientError.storageFailure
        }
    }

    private struct WAVLayout { let dataOffset: Int; let dataBytes: Int }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid() else {
            throw HarcDesktopClientError.unsafePath
        }
    }

    private static func wavLayout(_ bytes: Data) throws -> WAVLayout {
        var cursor = 12
        var formatValid = false
        var dataLayout: WAVLayout?
        while cursor + 8 <= bytes.count {
            let id = Data(bytes[cursor ..< cursor + 4])
            let size = Int(littleEndianUInt32(bytes, at: cursor + 4))
            let body = cursor + 8
            guard size >= 0, body <= bytes.count else {
                throw HarcDesktopClientError.invalidWAV
            }
            if id == Data("fmt ".utf8) {
                guard size >= 16, body + 16 <= bytes.count,
                      littleEndianUInt16(bytes, at: body) == 1,
                      littleEndianUInt16(bytes, at: body + 2) == 1,
                      littleEndianUInt32(bytes, at: body + 4) == 16_000,
                      littleEndianUInt16(bytes, at: body + 12) == 2,
                      littleEndianUInt16(bytes, at: body + 14) == 16 else {
                    throw HarcDesktopClientError.invalidWAV
                }
                formatValid = true
            } else if id == Data("data".utf8) {
                dataLayout = WAVLayout(dataOffset: body, dataBytes: size)
                break
            }
            let padded = size + (size & 1)
            guard body + padded > cursor else {
                throw HarcDesktopClientError.invalidWAV
            }
            cursor = body + padded
        }
        guard formatValid, let dataLayout else {
            throw HarcDesktopClientError.invalidWAV
        }
        return dataLayout
    }

    private static func littleEndianUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }

    private static func canonicalHeader(dataBytes: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        appendLittleEndian(dataBytes + 36, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt32(32_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataBytes, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { buffer in
            while written < data.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    data.count - written
                )
                guard result > 0 else { throw HarcDesktopClientError.storageFailure }
                written += result
            }
        }
    }
}

enum HarcDesktopClientError: LocalizedError {
    case installationIdentityLost
    case captureIdentityMismatch
    case missingDurableMaster
    case unsafePath
    case invalidWAV
    case destinationExists
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .installationIdentityLost:
            "The Desktop Client signing identity is missing; existing outbox recordings were left untouched."
        case .captureIdentityMismatch:
            "A durable Client capture belongs to another installation identity."
        case .missingDurableMaster:
            "A Client capture sidecar has no matching durable audio master."
        case .unsafePath:
            "The Desktop Client storage path is unsafe."
        case .invalidWAV:
            "The completed recording is not canonical 16 kHz mono PCM audio."
        case .destinationExists:
            "A Client capture destination already exists."
        case .storageFailure:
            "The Desktop Client could not durably store the recording."
        }
    }
}
