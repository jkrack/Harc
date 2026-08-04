#if canImport(Network)
import Foundation
import HarcHost
import HarcIdentity
import HarcStore
import Testing
@testable import HarcHostTransport

@Suite("Resident Host production composition")
struct ResidentHostRuntimeV1Tests {
    @Test("a pre-listener first-enable failure rolls canonical mode back")
    func firstEnableFailureRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HarcResidentHostRuntimeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let canonicalDB = root.appendingPathComponent("Harc.db")
        let hostDB = root.appendingPathComponent("HarcHost.db")
        let canonicalRoot = root.appendingPathComponent(
            "Recordings",
            isDirectory: true
        )
        let rollbackRoot = root.appendingPathComponent(
            "Rollback",
            isDirectory: true
        )
        let temporaryRoot = root.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        for directory in [canonicalRoot, rollbackRoot, temporaryRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let configuration = HarcResidentHostRuntimeConfigurationV1(
            storage: HarcResidentHostStorageConfiguration(
                canonicalDatabaseURL: canonicalDB,
                hostDatabaseURL: hostDB,
                stagingRoot: root.appendingPathComponent(
                    "Staging",
                    isDirectory: true
                ),
                listenerPorts: try HarcHostListenerPorts(
                    controlPort: 49_483,
                    uploadPort: 49_484
                )
            ),
            canonicalAudioRoot: canonicalRoot,
            backgroundRollbackRoot: rollbackRoot,
            temporaryUploadParent: temporaryRoot,
            displayName: "",
            localDNSTarget: "harc-test.local"
        )

        await #expect(throws: HarcHostError.invalidHostInfoInput("display name")) {
            _ = try await HarcResidentHostRuntimeV1.start(
                configuration: configuration,
                processingScheduler: AcceptingResidentProcessingScheduler(),
                cryptographicStateStore:
                    InMemoryHostCryptographicStateStore()
            )
        }

        let metadata = try RecordingStore.inspectLibraryMetadata(
            onDiskAt: canonicalDB
        )
        #expect(metadata.writerMode == .standalone)
        #expect(metadata.hostAuthorityID != nil)
        #expect(metadata.hostStateID != nil)
    }
}

private struct AcceptingResidentProcessingScheduler:
    HostReceiptDurableProcessingScheduling
{
    func schedule(_ request: HostDurableProcessingRequest) async throws {}
}
#endif
