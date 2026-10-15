import Foundation
import GRPCCore
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcTransfer
import Testing
@testable import HarcMobile

@Suite("Host Library refresh presentation")
@MainActor
struct HarcMobileLibraryRefreshPresentationTests {
    @Test("preserves actual RPC status instead of NSError's generic error 1")
    func actualRPCStatus() {
        for code in [RPCError.Code.cancelled, .deadlineExceeded, .permissionDenied, .unavailable] {
            let error = RPCError(code: code, message: "fixture-token user-transcript raw-request", cause: FixtureError.privateCause)
            #expect((error as NSError).code == 1)
            let message = HarcMobileLibraryRefreshPresentation.failureMessage(
                error, operation: .metadata, hasCachedRows: false
            )
            #expect(message.contains(code.description))
            #expect(!message.contains("fixture-token"))
            #expect(!message.contains("user-transcript"))
            #expect(!message.contains("raw-request"))
            #expect(!message.contains("privateCause"))
        }
    }

    @Test("never renders arbitrary localized errors or raw request details")
    func excludesUntrustedErrorDescriptions() {
        let message = HarcMobileLibraryRefreshPresentation.failureMessage(
            UntrustedError(), operation: .openingSession, hasCachedRows: false
        )
        #expect(message == "Host connection: Host request failed.")
        #expect(!message.contains("fixture-token"))
        #expect(!message.contains("user-transcript"))
        #expect(!message.contains("raw-request"))
    }

    @Test("identifies cached rows and the failed operation without discarding data")
    func cacheAndOperation() {
        let message = HarcMobileLibraryRefreshPresentation.failureMessage(
            RPCError(code: .unavailable, message: "Host unavailable"),
            operation: .speakerProfiles, hasCachedRows: true
        )
        #expect(message.hasPrefix("Showing cached Host Library. "))
        #expect(message.contains("Speaker profile update"))
        #expect(message.contains("unavailable"))
    }

    @Test("retry shows progress while retaining cached rows and does not open a network route")
    func retryWithCachedRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcLibraryRefresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = InMemorySoftwareInstallationKeyStore(initialKey: SoftwareP256SigningKey())
        let resolved = try await InstallationIdentityManager(keyStore: keyStore)
            .resolve(evidence: .cleanInstallation)
        guard case .available(let identity, _) = resolved else {
            Issue.record("Synthetic software identity unavailable")
            return
        }
        let store = try HarcTransferStore(rootDirectory: root, installationDeviceID: identity.deviceID)
        let cache = try HarcLibraryCache(rootDirectory: root)
        let summary = try LibraryRecordingSummary(
            canonicalID: .random(),
            originID: identity.originRecordingID(),
            revision: EntityRevision(1),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_010),
            title: "Synthetic cached metadata"
        )
        try cache.replace(with: AnchoredLibrarySnapshot(
            libraryID: .random(), anchor: ChangeCursor(1),
            recordings: [summary], tombstones: []
        ))
        let coordinator = HarcMobileLibraryCoordinator(
            identity: identity, transferStore: store, cache: cache,
            routeURL: root.appendingPathComponent("no-route.json")
        )
        #expect(try store.activeAdoption() == nil)
        coordinator.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.isRefreshing && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!coordinator.isRefreshing)
        guard case .offline = coordinator.state else {
            coordinator.shutdown()
            Issue.record("The unpaired fixture must retain its cached view")
            return
        }
        coordinator.refresh()
        #expect(coordinator.state == .refreshing)
        #expect(coordinator.recordings == [summary])
        coordinator.shutdown()
        await Task.yield()
    }

    private enum FixtureError: Error { case privateCause }

    private struct UntrustedError: LocalizedError {
        var errorDescription: String? {
            "fixture-token user-transcript raw-request"
        }
    }
}
