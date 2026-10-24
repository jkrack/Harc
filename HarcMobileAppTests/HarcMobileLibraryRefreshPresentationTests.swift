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
    @Test("zero-row presentation distinguishes loading, empty, unpaired, denied, cancelled and failure")
    func emptyLibraryStates() {
        let states: [HarcMobileLibraryCoordinator.State] = [
            .loadingCache, .refreshing, .ready(lastUpdated: Date()),
            .unpaired, .accessNotGranted, .cancelled,
            .failed("Library metadata refresh: Host request failed (unavailable).")
        ]
        let statuses = states.map {
            HarcMobileLibraryRefreshPresentation.status($0, hasRows: false)
        }
        #expect(Set(statuses.map(\.title)).count == states.count)
        #expect(statuses.map(\.isLoading) == [true, true, false, false, false, false, false])
        #expect(statuses.map(\.action) == [nil, nil, .refresh, .setup, .setup, .refresh, .refresh])
        #expect(statuses[2].title == "No recordings yet")
        #expect(statuses[6].detail.contains("unavailable"))
        for status in statuses {
            #expect(!status.title.contains("up to date"))
            #expect(!status.detail.isEmpty)
        }
    }

    @Test("cached and zero-row failures use the same retained sanitized reason and retry")
    func visibleFailureReasons() {
        for hasRows in [false, true] {
            let message = HarcMobileLibraryRefreshPresentation.failureMessage(
                RPCError(code: .permissionDenied, message: "private fixture-token"),
                operation: .metadata, hasCachedRows: hasRows
            )
            for state in [HarcMobileLibraryCoordinator.State.failed(message), .offline(message: message)] {
                let status = HarcMobileLibraryRefreshPresentation.status(state, hasRows: hasRows)
                #expect(status.detail == message)
                #expect(status.detail.count <= 140)
                #expect(!status.detail.contains("fixture-token"))
                #expect(status.action == .refresh)
                #expect(!status.isLoading)
                #expect(status.title != "No recordings yet")
            }
        }
    }

    private func visibleStatus(_ coordinator: HarcMobileLibraryCoordinator)
        -> HarcMobileLibraryRefreshPresentation.Status {
        HarcMobileLibraryRefreshPresentation.status(
            coordinator.state, hasRows: !coordinator.recordings.isEmpty
        )
    }

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
        try await withTemporaryRoot(prefix: "HarcLibraryRefresh") { root in
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
    }

    @Test("initial and cached loads identify every failed stage and retain durable metadata",
          arguments: [false, true], refreshOperations)
    func stageFailures(cached: Bool, operation: HarcMobileLibraryRefreshOperation) async throws {
        try await withRefreshFixture(cached: cached) { fixture in
            let coordinator = fixture.coordinator {
                try fixture.open(failingAt: operation)
            }
            defer { coordinator.shutdown() }
            coordinator.refresh()
            #expect(coordinator.state == .refreshing)
            try await waitUntil { !coordinator.isRefreshing }

            let metadataWasPublished = operation == .speakerProfiles || operation == .finishing
            let hasRows = cached || metadataWasPublished
            let message: String
            switch coordinator.state {
            case .offline(let value) where hasRows: message = value
            case .failed(let value) where !hasRows: message = value
            default:
                Issue.record("Wrong failure state for initial/cached load")
                return
            }
            #expect(message.contains(operation.rawValue))
            #expect(message.contains("unavailable"))
            #expect(message.hasPrefix("Showing cached Host Library.") == hasRows)
            let expected = metadataWasPublished ? fixture.updated : fixture.original
            #expect(coordinator.recordings == (hasRows ? [expected] : []))
            let failedIndex = try #require(Self.refreshOperations.firstIndex(of: operation))
            #expect(fixture.events == Array(Self.refreshOperations.prefix(through: failedIndex)))
            #expect(fixture.aborts == (operation == .openingSession ? 0 : 1))
        }
    }

    @Test("successful retry clears the error and publishes the updated cached Library", arguments: [false, true])
    func retryRecovers(cached: Bool) async throws {
        try await withRefreshFixture(cached: cached) { fixture in
            var attempt = 0
            let coordinator = fixture.coordinator {
                attempt += 1
                return try fixture.open(failingAt: attempt == 1 ? .metadata : nil)
            }
            defer { coordinator.shutdown() }
            coordinator.refresh()
            try await waitUntil { !coordinator.isRefreshing }
            let failedStatus = visibleStatus(coordinator)
            #expect(failedStatus.action == .refresh)
            coordinator.shutdown() // Dismissing an idle surface must retain failure.
            #expect(visibleStatus(coordinator) == failedStatus)
            coordinator.refresh()
            #expect(coordinator.state == .refreshing)
            #expect(visibleStatus(coordinator).isLoading)
            #expect(visibleStatus(coordinator).action == nil)
            coordinator.refresh() // Repeated retry must not start another session.
            try await waitUntil { !coordinator.isRefreshing }
            guard case .ready(let updatedAt) = coordinator.state else {
                Issue.record("Successful retry must clear the previous error")
                return
            }
            #expect(updatedAt != nil)
            #expect(coordinator.recordings == [fixture.updated])
            #expect(attempt == 2)
            #expect(fixture.aborts == 1)
        }
    }

    @Test("cancelled response and cleanup cannot replace or clear a newer refresh",
          arguments: [false, true], [false, true])
    func staleMetadataResponse(oldFails: Bool, oldCompletesFirst: Bool) async throws {
        try await withRefreshFixture(cached: true) { fixture in
            let old = RefreshGate(), current = RefreshGate()
            var opens = 0
            var aborts = 0
            let coordinator = fixture.coordinator {
                opens += 1
                let first = opens == 1
                return HarcMobileLibraryRefreshSession(
                    protectedEdits: nil,
                    metadata: {
                        await (first ? old : current).wait()
                        if first && oldFails { throw RPCError(code: .unavailable, message: "private old response") }
                    },
                    speakerProfiles: nil, finish: {}, abort: { aborts += 1 }
                )
            }
            defer { coordinator.shutdown(); old.release(); current.release() }
            coordinator.refresh()
            try await waitUntil { old.entered }
            coordinator.refresh()
            #expect(opens == 1) // Coalesce an active refresh.
            coordinator.shutdown()
            coordinator.refresh()
            try await waitUntil { current.entered }
            if oldCompletesFirst {
                old.release()
                try await waitUntil { aborts == 1 }
                #expect(coordinator.isRefreshing)
                #expect(coordinator.state == .refreshing)
                coordinator.refresh()
                #expect(opens == 2) // Old cleanup must not drop the new task handle.
                current.release()
                try await waitUntil { !coordinator.isRefreshing }
            } else {
                current.release()
                try await waitUntil { !coordinator.isRefreshing }
                let readyState = coordinator.state
                old.release()
                try await waitUntil { aborts == 1 }
                #expect(coordinator.state == readyState)
                #expect(!coordinator.isRefreshing)
            }
            guard case .ready = coordinator.state else {
                Issue.record("Only the current refresh may publish its result")
                return
            }
            #expect(coordinator.recordings == [fixture.original])
            #expect(opens == 2)
        }
    }

    @Test("shutdown leaves a terminal cancellation state before and after a late completion",
          arguments: [false, true], [false, true])
    func shutdownTerminates(cached: Bool, lateFailure: Bool) async throws {
        try await withRefreshFixture(cached: cached) { fixture in
            let pending = RefreshGate()
            var aborts = 0
            let coordinator = fixture.coordinator {
                HarcMobileLibraryRefreshSession(
                    protectedEdits: nil,
                    metadata: {
                        await pending.wait()
                        if lateFailure { throw RPCError(code: .unavailable, message: "private late failure") }
                    },
                    speakerProfiles: nil, finish: {}, abort: { aborts += 1 }
                )
            }
            defer { coordinator.shutdown(); pending.release() }
            coordinator.refresh()
            try await waitUntil { pending.entered }
            coordinator.shutdown()
            #expect(!coordinator.isRefreshing)
            #expect(coordinator.state == .cancelled)
            #expect(visibleStatus(coordinator).title == "Library refresh cancelled")
            #expect(visibleStatus(coordinator).action == .refresh)
            pending.release()
            try await waitUntil { aborts == 1 }
            #expect(!coordinator.isRefreshing)
            #expect(coordinator.state == .cancelled)
            #expect(visibleStatus(coordinator).title == "Library refresh cancelled")
            #expect(coordinator.recordings == (cached ? [fixture.original] : []))
        }
    }

    @Test("a session returned after cancellation is aborted without changing the newer result")
    func staleOpenedSession() async throws {
        try await withRefreshFixture(cached: false) { fixture in
            let old = RefreshGate()
            var opens = 0, aborts = 0, metadataCalls = 0
            let coordinator = fixture.coordinator {
                opens += 1
                if opens == 1 { await old.wait() }
                return HarcMobileLibraryRefreshSession(
                    protectedEdits: nil, metadata: { metadataCalls += 1 },
                    speakerProfiles: nil, finish: {}, abort: { aborts += 1 }
                )
            }
            defer { coordinator.shutdown(); old.release() }
            coordinator.refresh()
            try await waitUntil { old.entered }
            coordinator.shutdown()
            coordinator.refresh()
            try await waitUntil { !coordinator.isRefreshing }
            let readyState = coordinator.state
            old.release()
            try await waitUntil { aborts == 1 }
            #expect(coordinator.state == readyState)
            #expect(metadataCalls == 1)
            #expect(opens == 2)
        }
    }

    @Test("a grant without metadata access closes cleanly and never runs Library work", arguments: [false, true])
    func metadataAccessDenied(cached: Bool) async throws {
        try await withRefreshFixture(cached: cached) { fixture in
            var finished = false
            let coordinator = fixture.coordinator {
                HarcMobileLibraryRefreshSession(
                    protectedEdits: { Issue.record("Edits must not run without read access") },
                    metadata: nil,
                    speakerProfiles: { Issue.record("Speaker work must not run without read access") },
                    finish: { finished = true }, abort: { Issue.record("Clean denial should close gracefully") }
                )
            }
            defer { coordinator.shutdown() }
            coordinator.refresh()
            try await waitUntil { !coordinator.isRefreshing }
            #expect(coordinator.state == .accessNotGranted)
            #expect(visibleStatus(coordinator).title == "Mac Library access not granted")
            #expect(visibleStatus(coordinator).action == .setup)
            #expect(finished)
            #expect(coordinator.recordings == (cached ? [fixture.original] : []))
        }
    }

    @Test("known pairing repair keeps fixed actionable guidance and cached rows", arguments: [false, true])
    func pairingRepairGuidance(cached: Bool) async throws {
        try await withRefreshFixture(cached: cached) { fixture in
            let coordinator = fixture.coordinator {
                throw HarcMobileHostSessionConnectorError.pairingRepairRequired
            }
            defer { coordinator.shutdown() }
            coordinator.refresh()
            try await waitUntil { !coordinator.isRefreshing }
            let message: String
            switch coordinator.state {
            case .offline(let value) where cached: message = value
            case .failed(let value) where !cached: message = value
            default:
                Issue.record("Pairing repair must preserve the initial/cached failure state")
                return
            }
            #expect(message.contains("Recordings are safe on this iPhone."))
            #expect(message.contains("Forget this Host, create a new invitation, and pair again."))
            #expect(message.hasPrefix("Showing cached Host Library.") == cached)
            #expect(message.count <= 240)
            #expect(coordinator.recordings == (cached ? [fixture.original] : []))
        }
    }

    @Test("error text stays bounded for every operation despite oversized untrusted payloads")
    func boundedDiagnostics() {
        let payload = String(repeating: "fixture-token user-transcript raw-request ", count: 10_000)
        for operation in Self.refreshOperations {
            let message = HarcMobileLibraryRefreshPresentation.failureMessage(
                RPCError(code: .permissionDenied, message: payload), operation: operation, hasCachedRows: true
            )
            #expect(message.count <= 140)
            #expect(message.contains("permissionDenied"))
            #expect(!message.contains("fixture-token"))
            #expect(!message.contains("user-transcript"))
            #expect(!message.contains("raw-request"))
        }
    }

    nonisolated private static let refreshOperations: [HarcMobileLibraryRefreshOperation] = [
        .openingSession, .protectedEdits, .metadata, .speakerProfiles, .finishing
    ]

    private func withRefreshFixture(
        cached: Bool,
        _ body: (RefreshFixture) async throws -> Void
    ) async throws {
        try await withTemporaryRoot(prefix: "HarcRefreshLifecycle") { root in
            let fixture = try await RefreshFixture(root: root, cached: cached)
            try await body(fixture)
        }
    }

    private func withTemporaryRoot(
        prefix: String,
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try await body(root)
            try FileManager.default.removeItem(at: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        guard predicate() else { throw FixtureError.deadline }
    }

    @MainActor
    private final class RefreshGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var entered = false
        // Deliberately ignore task cancellation to model a late RPC completion.
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() {
            released = true
            let waiting = continuations
            continuations = []
            for continuation in waiting { continuation.resume() }
        }
    }

    @MainActor
    private final class RefreshFixture {
        let root: URL
        let cache: HarcLibraryCache
        let store: HarcTransferStore
        let identity: InstallationSigningIdentity
        let libraryID = LibraryID.random()
        let original: LibraryRecordingSummary
        let updated: LibraryRecordingSummary
        var events: [HarcMobileLibraryRefreshOperation] = []
        var aborts = 0

        init(root: URL, cached: Bool) async throws {
            self.root = root
            let keyStore = InMemorySoftwareInstallationKeyStore(initialKey: SoftwareP256SigningKey())
            let resolved = try await InstallationIdentityManager(keyStore: keyStore).resolve(evidence: .cleanInstallation)
            guard case .available(let identity, _) = resolved else { throw FixtureError.identity }
            self.identity = identity
            store = try HarcTransferStore(rootDirectory: root, installationDeviceID: identity.deviceID)
            cache = try HarcLibraryCache(rootDirectory: root)
            let canonicalID = CanonicalRecordingID.random()
            let originID = identity.originRecordingID()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            original = try LibraryRecordingSummary(
                canonicalID: canonicalID, originID: originID, revision: EntityRevision(1),
                startedAt: start, endedAt: start.addingTimeInterval(10),
                title: "Synthetic cached metadata"
            )
            updated = try LibraryRecordingSummary(
                canonicalID: canonicalID, originID: originID, revision: EntityRevision(2),
                startedAt: start, endedAt: start.addingTimeInterval(10),
                title: "Synthetic updated metadata"
            )
            if cached { try publish(original, anchor: 1) }
        }
        func publish(_ recording: LibraryRecordingSummary, anchor: UInt64) throws {
            try cache.replace(with: AnchoredLibrarySnapshot(
                libraryID: libraryID, anchor: ChangeCursor(anchor),
                recordings: [recording], tombstones: []
            ))
        }
        func coordinator(opener: @escaping HarcMobileLibraryRefreshSession.Opener) -> HarcMobileLibraryCoordinator {
            HarcMobileLibraryCoordinator(
                identity: identity, transferStore: store, cache: cache,
                routeURL: root.appendingPathComponent("no-route.json"),
                refreshSessionOpener: opener
            )
        }
        func open(failingAt failure: HarcMobileLibraryRefreshOperation?) throws -> HarcMobileLibraryRefreshSession {
            try enter(.openingSession, failingAt: failure)
            return HarcMobileLibraryRefreshSession(
                protectedEdits: { try self.enter(.protectedEdits, failingAt: failure) },
                metadata: {
                    try self.enter(.metadata, failingAt: failure)
                    try self.publish(self.updated, anchor: 2)
                },
                speakerProfiles: { try self.enter(.speakerProfiles, failingAt: failure) },
                finish: { try self.enter(.finishing, failingAt: failure) },
                abort: { self.aborts += 1 }
            )
        }
        func enter(_ operation: HarcMobileLibraryRefreshOperation, failingAt failure: HarcMobileLibraryRefreshOperation?) throws {
            events.append(operation)
            if operation == failure { throw RPCError(code: .unavailable, message: "untrusted fixture request body") }
        }
    }

    private enum FixtureError: Error { case privateCause, deadline, identity }

    private struct UntrustedError: LocalizedError {
        var errorDescription: String? {
            "fixture-token user-transcript raw-request"
        }
    }
}
