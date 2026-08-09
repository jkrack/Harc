import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcTransfer
import Observation
import UIKit

enum HarcMobileCaptureQualificationError: LocalizedError, Equatable {
    case duplicateStorageExhaustionArgument
    case missingStorageExhaustionValue
    case invalidStorageExhaustionValue(String)

    var errorDescription: String? {
        switch self {
        case .duplicateStorageExhaustionArgument:
            "The capture storage-exhaustion qualification argument was repeated."
        case .missingStorageExhaustionValue:
            "The capture storage-exhaustion qualification argument needs a byte value."
        case .invalidStorageExhaustionValue(let value):
            "The capture storage-exhaustion qualification byte value is invalid: \(value)."
        }
    }
}

enum HarcMobileUITestConfigurationError: LocalizedError, Equatable {
    case duplicateRootArgument
    case missingRootValue
    case invalidRootValue(String)
    case duplicateResetRootArgument
    case resetRootWithoutRootID

    var errorDescription: String? {
        switch self {
        case .duplicateRootArgument:
            "The UI-test root argument was repeated."
        case .missingRootValue:
            "The UI-test root argument needs a UUID value."
        case .invalidRootValue(let value):
            "The UI-test root UUID is invalid: \(value)."
        case .duplicateResetRootArgument:
            "The UI-test reset-root argument was repeated."
        case .resetRootWithoutRootID:
            "The UI-test reset-root argument requires a scoped root UUID."
        }
    }
}

enum HarcMobileUITestConfiguration {
    static let rootArgument = "--harc-ui-test-root-id"
    static let resetRootArgument = "--harc-ui-test-reset-root"

    static func rootID(arguments: [String]) throws -> UUID? {
#if DEBUG
        let indices = arguments.indices.filter {
            arguments[$0] == rootArgument
        }
        guard indices.count <= 1 else {
            throw HarcMobileUITestConfigurationError.duplicateRootArgument
        }
        guard let index = indices.first else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw HarcMobileUITestConfigurationError.missingRootValue
        }
        let rawValue = arguments[valueIndex]
        guard let value = UUID(uuidString: rawValue),
              value.uuidString == rawValue.uppercased() else {
            throw HarcMobileUITestConfigurationError
                .invalidRootValue(rawValue)
        }
        return value
#else
        return nil
#endif
    }

    static func shouldResetRoot(
        arguments: [String],
        rootID: UUID?
    ) throws -> Bool {
#if DEBUG
        let count = arguments.count { $0 == resetRootArgument }
        guard count <= 1 else {
            throw HarcMobileUITestConfigurationError
                .duplicateResetRootArgument
        }
        guard count == 1 else { return false }
        guard rootID != nil else {
            throw HarcMobileUITestConfigurationError.resetRootWithoutRootID
        }
        return true
#else
        return false
#endif
    }
}

enum HarcMobileCaptureQualificationConfiguration {
    static let storageExhaustionArgument =
        "--harc-capture-storage-exhaustion-after-canonical-bytes"

    static func storageExhaustionAfterCanonicalBytes(
        arguments: [String]
    ) throws -> UInt64? {
#if DEBUG
        let indices = arguments.indices.filter {
            arguments[$0] == storageExhaustionArgument
        }
        guard indices.count <= 1 else {
            throw HarcMobileCaptureQualificationError
                .duplicateStorageExhaustionArgument
        }
        guard let index = indices.first else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw HarcMobileCaptureQualificationError
                .missingStorageExhaustionValue
        }
        let rawValue = arguments[valueIndex]
        guard let value = UInt64(rawValue),
              value >= HarcMobileDurableMasterWriter.checkpointFrames * 2,
              value.isMultiple(of: 2) else {
            throw HarcMobileCaptureQualificationError
                .invalidStorageExhaustionValue(rawValue)
        }
        return value
#else
        return nil
#endif
    }
}

@MainActor
@Observable
final class HarcMobileAppModel {
    enum Readiness: Equatable {
        case starting
        case ready(deviceID: DeviceID, recoveredRecordings: Int)
        case protectedDataUnavailable
        case keyLoss
        case failed(String)
    }

    private(set) var readiness: Readiness = .starting
    private(set) var bootstrapCompleted = false
    private(set) var captureCoordinator: HarcMobileCaptureCoordinator?
    private(set) var pairingCoordinator: HarcMobilePairingCoordinator?
    private(set) var transferCoordinator: HarcMobileTransferCoordinator?
    private(set) var libraryCoordinator: HarcMobileLibraryCoordinator?
    private var transferStore: HarcTransferStore?
    private var backgroundUploadClient:
        HarcBackgroundURLSessionUploadClientV1?

    func bootstrap() async {
        guard !bootstrapCompleted else { return }
        bootstrapCompleted = true
        do {
            guard UIApplication.shared.isProtectedDataAvailable else {
                readiness = .protectedDataUnavailable
                return
            }
            let processArguments = ProcessInfo.processInfo.arguments
            let qualificationStorageExhaustionBytes = try
                HarcMobileCaptureQualificationConfiguration
                    .storageExhaustionAfterCanonicalBytes(
                        arguments: processArguments
                    )
            let uiTestRootID = try HarcMobileUITestConfiguration.rootID(
                arguments: processArguments
            )
            let shouldResetUITestRoot = try HarcMobileUITestConfiguration
                .shouldResetRoot(
                    arguments: processArguments,
                    rootID: uiTestRootID
                )
            let root = try Self.applicationRoot(
                uiTestRootID: uiTestRootID,
                resetUITestRoot: shouldResetUITestRoot
            )
            let clientLocations = try ClientStoreLocations(rootDirectory: root)
            let captureLocations = try HarcMobileCaptureLocations(
                applicationSupportRoot: root
            )
            let routeURL = root.appendingPathComponent("host-route.json")
            let hasPriorState = FileManager.default.fileExists(
                atPath: clientLocations.transferDatabase.path
            ) || FileManager.default.fileExists(atPath: routeURL.path)
            let hasCaptureState = try Self.hasCaptureState(captureLocations)
            let identityManager = InstallationIdentityManager(
                keyStore: KeychainSoftwareInstallationKeyStore(
                    service: Self.identityKeyService(
                        uiTestRootID: uiTestRootID
                    ),
                    account: "device-p256-signing-v1",
                    domain: .dataProtection
                )
            )
            let resolution = try await identityManager.resolve(
                evidence: InstallationIdentityEvidence(
                    hasPriorIdentityState: hasPriorState,
                    hasIdentityBoundCaptures: hasCaptureState
                )
            )
            guard case .available(let identity, _) = resolution else {
                readiness = .keyLoss
                return
            }
            let store = try HarcTransferStore(
                rootDirectory: root,
                installationDeviceID: identity.deviceID
            )
            let libraryCache = try HarcLibraryCache(rootDirectory: root)
            try Self.protectTransferState(
                root: root,
                locations: clientLocations
            )
            let recovered = try HarcMobileCaptureRecovery
                .recoverDurablePrefixes(locations: captureLocations)
            for master in recovered {
                _ = try store.persistFinalizedCapture(
                    try Self.finalizedCapture(master),
                    masterFileURL: master.masterFileURL
                )
            }
            try Self.rebaseRelocatedArtifactPaths(
                store: store,
                locations: captureLocations,
                currentRoot: root
            )
            try Self.protectTransferState(
                root: root,
                locations: clientLocations
            )
            transferStore = store
            let backgroundEventRelay =
                HarcMobileBackgroundTransferEventRelay()
            let backgroundClient =
                HarcBackgroundURLSessionUploadClientV1.makeProduction(
                    store: store,
                    completionReporter: { _ in
#if DEBUG
                        print("[Harc host-transfer] background task ACK persisted")
#endif
                        await backgroundEventRelay.didFinish()
                    },
                    failureReporter: { failure in
#if DEBUG
                        print(
                            "[Harc host-transfer] background task "
                            + "\(failure.taskIdentifier) failed: "
                            + failure.errorDescription
                        )
#endif
                        await backgroundEventRelay.didFinish()
                    }
                )
            backgroundUploadClient = backgroundClient
            HarcMobileBackgroundSessionBridge.shared.attach(backgroundClient)
            let transfer = HarcMobileTransferCoordinator(
                identity: identity,
                store: store,
                locations: captureLocations,
                routeURL: routeURL,
                backgroundUploadClient: backgroundClient
            )
            transferCoordinator = transfer
            await backgroundEventRelay.attach(transfer)
            let library = HarcMobileLibraryCoordinator(
                identity: identity,
                transferStore: store,
                cache: libraryCache,
                routeURL: routeURL
            )
            libraryCoordinator = library
            captureCoordinator = HarcMobileCaptureCoordinator(
                producingDeviceID: identity.deviceID,
                locations: captureLocations,
                storageExhaustionAfterCanonicalBytesForTesting:
                    qualificationStorageExhaustionBytes
            ) { [weak self] master in
                guard let self, let store = self.transferStore else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try store.persistFinalizedCapture(
                    try Self.finalizedCapture(master),
                    masterFileURL: master.masterFileURL
                )
                self.transferCoordinator?.enqueue(master)
            }
            pairingCoordinator = HarcMobilePairingCoordinator(
                identity: identity,
                store: store,
                routeURL: routeURL,
                hasActiveAdoption: try store.activeAdoption() != nil
            ) { [weak self] in
                self?.transferCoordinator?.retryPending()
                self?.libraryCoordinator?.refresh()
            }
            readiness = .ready(
                deviceID: identity.deviceID,
                recoveredRecordings: recovered.count
            )
            // Reconcile the durable background state before considering a
            // foreground retry. Reconciliation calls retryPending() after it
            // has repaired any terminal task state, preventing a stale queued
            // recording from racing ahead of a persisted security block.
            transfer.reconcileBackgroundUploads()
            library.refresh()
        } catch {
            readiness = .failed(error.localizedDescription)
        }
    }

    func retryAfterProtectedDataBecomesAvailable() async {
        guard readiness == .protectedDataUnavailable else { return }
        bootstrapCompleted = false
        readiness = .starting
        await bootstrap()
    }

    private static func rebaseRelocatedArtifactPaths(
        store: HarcTransferStore,
        locations: HarcMobileCaptureLocations,
        currentRoot: URL
    ) throws {
        let currentRoot = currentRoot.standardizedFileURL
        var staleRoots = Set<URL>()
        for outbox in try store.recordingOutboxes() {
            let stored = outbox.finalizedCapture.masterFileURL
                .standardizedFileURL
            let current = locations.finalizedMasterURL(
                recordingUUID: outbox.finalizedCapture.capture
                    .originRecordingID.recordingUUID
            ).standardizedFileURL
            guard stored != current,
                  !FileManager.default.fileExists(atPath: stored.path),
                  FileManager.default.fileExists(atPath: current.path)
            else { continue }
            let staleRoot = stored
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .standardizedFileURL
            staleRoots.insert(staleRoot)
        }
        for staleRoot in staleRoots where staleRoot != currentRoot {
            try store.rebaseLocalArtifactPaths(
                from: staleRoot,
                to: currentRoot
            )
        }
    }

    private static func applicationRoot(
        uiTestRootID: UUID?,
        resetUITestRoot: Bool
    ) throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root: URL
        if let uiTestRootID {
            root = base
                .appendingPathComponent("HarcMobileUITests", isDirectory: true)
                .appendingPathComponent(
                    uiTestRootID.uuidString,
                    isDirectory: true
                )
        } else {
            root = base.appendingPathComponent(
                "HarcMobile",
                isDirectory: true
            )
        }
        if resetUITestRoot {
            guard uiTestRootID != nil else {
                throw HarcMobileUITestConfigurationError
                    .resetRootWithoutRootID
            }
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func identityKeyService(uiTestRootID: UUID?) -> String {
        guard let uiTestRootID else {
            return "com.harc.Harc.mobile.installation-identity"
        }
        return "com.harc.Harc.mobile.installation-identity.ui-test.\(uiTestRootID.uuidString)"
    }

    private static func hasCaptureState(
        _ locations: HarcMobileCaptureLocations
    ) throws -> Bool {
        for directory in [locations.active, locations.finalized]
        where FileManager.default.fileExists(atPath: directory.path) {
            if try !FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).isEmpty {
                return true
            }
        }
        return false
    }

    private static func protectTransferState(
        root: URL,
        locations: ClientStoreLocations
    ) throws {
        let attributes = FoundationHarcMobileCaptureStorageAttributes()
        try attributes.applyAndVerify(.transferArtifact, to: root)
        let database = locations.transferDatabase
        for url in [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try attributes.applyAndVerify(.transferArtifact, to: url)
        }
    }

    private static func finalizedCapture(
        _ master: HarcMobileFinalizedMaster
    ) throws -> FinalizedCapture {
        let reason: CaptureFinalizationReason = switch master.finalizationReason {
        case .userStopped: .userStopped
        case .systemEnded: .systemEnded
        case .recoveredDurablePrefix: .recoveredDurablePrefix
        case .storageExhausted: .storageExhausted
        case .writerFailure: .writerFailure
        }
        return try FinalizedCapture(
            producingDeviceID: master.producingDeviceID,
            originRecordingID: master.originRecordingID,
            captureStartedAt: master.captureStartedAt,
            captureEndedAt: master.captureEndedAt,
            captureStartedMonotonicNanoseconds:
                master.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                master.captureEndedMonotonicNanoseconds,
            finalizationReason: reason,
            totalCanonicalFrames: master.totalCanonicalFrames,
            totalCanonicalBytes: master.totalCanonicalBytes,
            canonicalPCMSHA256: master.canonicalPCMSHA256,
            discontinuities: master.discontinuities
        )
    }
}

private actor HarcMobileBackgroundTransferEventRelay {
    private weak var coordinator: HarcMobileTransferCoordinator?

    func attach(_ coordinator: HarcMobileTransferCoordinator) {
        self.coordinator = coordinator
    }

    func didFinish() async {
        await coordinator?.reconcileBackgroundUploads()
    }
}
