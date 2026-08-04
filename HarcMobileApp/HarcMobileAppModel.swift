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

    var errorDescription: String? {
        switch self {
        case .duplicateRootArgument:
            "The UI-test root argument was repeated."
        case .missingRootValue:
            "The UI-test root argument needs a UUID value."
        case .invalidRootValue(let value):
            "The UI-test root UUID is invalid: \(value)."
        }
    }
}

enum HarcMobileUITestConfiguration {
    static let rootArgument = "--harc-ui-test-root-id"

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
            let qualificationStorageExhaustionBytes = try
                HarcMobileCaptureQualificationConfiguration
                    .storageExhaustionAfterCanonicalBytes(
                        arguments: ProcessInfo.processInfo.arguments
                    )
            let uiTestRootID = try HarcMobileUITestConfiguration.rootID(
                arguments: ProcessInfo.processInfo.arguments
            )
            let root = try Self.applicationRoot(uiTestRootID: uiTestRootID)
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
                    account: "device-p256-signing-v1"
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
                        await backgroundEventRelay.didFinish()
                    },
                    failureReporter: { _ in
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

    private static func applicationRoot(uiTestRootID: UUID?) throws -> URL {
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
