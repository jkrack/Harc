import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcTransfer
import Observation
import UIKit

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
    private var transferStore: HarcTransferStore?

    func bootstrap() async {
        guard !bootstrapCompleted else { return }
        bootstrapCompleted = true
        do {
            guard UIApplication.shared.isProtectedDataAvailable else {
                readiness = .protectedDataUnavailable
                return
            }
            let root = try Self.applicationRoot()
            let clientLocations = try ClientStoreLocations(rootDirectory: root)
            let hasPriorState = FileManager.default.fileExists(
                atPath: clientLocations.transferDatabase.path
            )
            let identityManager = InstallationIdentityManager(
                keyStore: KeychainSoftwareInstallationKeyStore(
                    service: "com.harc.Harc.mobile.installation-identity",
                    account: "device-p256-signing-v1"
                )
            )
            let resolution = try await identityManager.resolve(
                evidence: InstallationIdentityEvidence(
                    hasPriorIdentityState: hasPriorState
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
            let captureLocations = try HarcMobileCaptureLocations(
                applicationSupportRoot: root
            )
            let recovered = try HarcMobileCaptureRecovery
                .recoverDurablePrefixes(locations: captureLocations)
            for master in recovered {
                _ = try store.persistFinalizedCapture(
                    try Self.finalizedCapture(master),
                    masterFileURL: master.masterFileURL
                )
            }
            transferStore = store
            captureCoordinator = HarcMobileCaptureCoordinator(
                producingDeviceID: identity.deviceID,
                locations: captureLocations
            ) { [weak self] master in
                guard let self, let store = self.transferStore else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try store.persistFinalizedCapture(
                    try Self.finalizedCapture(master),
                    masterFileURL: master.masterFileURL
                )
            }
            readiness = .ready(
                deviceID: identity.deviceID,
                recoveredRecordings: recovered.count
            )
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

    private static func applicationRoot() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = base.appendingPathComponent("HarcMobile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
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
