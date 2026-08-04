import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation

@MainActor
@Observable
final class HarcMobileLibraryCoordinator {
    enum State: Equatable {
        case loadingCache
        case unpaired
        case accessNotGranted
        case refreshing
        case ready(lastUpdated: Date?)
        case offline(message: String)
        case failed(String)
    }

    private(set) var state: State = .loadingCache
    private(set) var recordings: [LibraryRecordingSummary] = []
    private(set) var isRefreshing = false

    private let identity: InstallationSigningIdentity
    private let transferStore: HarcTransferStore
    private let cache: HarcLibraryCache
    private let routeURL: URL
    private var refreshTask: Task<Void, Never>?

    init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        cache: HarcLibraryCache,
        routeURL: URL
    ) {
        self.identity = identity
        self.transferStore = transferStore
        self.cache = cache
        self.routeURL = routeURL
        loadCachedView()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        if recordings.isEmpty { state = .refreshing }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    func recordingDetail(
        canonicalID: CanonicalRecordingID
    ) async throws -> LibraryRecordingDetail {
        let opened = try await HarcMobileHostSessionConnector.open(
            identity: identity,
            store: transferStore,
            routeURL: routeURL
        )
        do {
            guard opened.adoption.grant.scopes.contains(
                .libraryMetadataRead
            ) else {
                throw HarcMobileLibraryError.accessNotGranted
            }
            var request = Harc_V1_GetRecordingRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.canonicalRecordingID =
                Harc_V1_CanonicalRecordingIDV1(canonicalID)
            request.requestedFields = [
                .recordingDetailFieldMetadata,
                .recordingDetailFieldTranscript,
                .recordingDetailFieldSpeakerLabels,
                .recordingDetailFieldSummary,
                .recordingDetailFieldActionItems,
                .recordingDetailFieldNotes,
                .recordingDetailFieldDiscontinuities,
            ]
            let response = try await opened.connection.getLibraryRecording(
                request,
                authorization: try HarcLibraryAuthorization(
                    openedSession: opened.session
                )
            )
            try Self.validateProtocol(response.hasProtocol, response.protocol)
            guard response.hasRecording else {
                throw HarcMobileLibraryError.malformedResponse
            }
            let detail = try response.recording.domainValue()
            guard detail.summary.canonicalID == canonicalID else {
                throw HarcMobileLibraryError.malformedResponse
            }
            try await opened.connection.shutdownGracefully()
            return detail
        } catch {
            await opened.connection.shutdownImmediately()
            throw error
        }
    }

    private func performRefresh() async {
        defer {
            isRefreshing = false
            refreshTask = nil
        }
        do {
            let opened = try await HarcMobileHostSessionConnector.open(
                identity: identity,
                store: transferStore,
                routeURL: routeURL
            )
            do {
                guard opened.adoption.grant.scopes.contains(
                    .libraryMetadataRead
                ) else {
                    state = .accessNotGranted
                    try await opened.connection.shutdownGracefully()
                    return
                }
                let authorization = try HarcLibraryAuthorization(
                    openedSession: opened.session
                )
                try await synchronize(
                    opened: opened,
                    authorization: authorization,
                    mayRestartSnapshot: true
                )
                try await opened.connection.shutdownGracefully()
                loadCachedView()
                state = .ready(lastUpdated: try cache.state()?.updatedAt)
            } catch {
                await opened.connection.shutdownImmediately()
                throw error
            }
        } catch HarcMobileHostSessionConnectorError.notPaired {
            state = recordings.isEmpty ? .unpaired : .offline(
                message: "Showing the protected local cache. Pair a Host to refresh."
            )
        } catch {
            loadCachedView()
            state = recordings.isEmpty
                ? .failed(error.localizedDescription)
                : .offline(message: error.localizedDescription)
        }
    }

    private func synchronize(
        opened: HarcMobileOpenedHostConnection,
        authorization: HarcLibraryAuthorization,
        mayRestartSnapshot: Bool
    ) async throws {
        let current = try cache.state()
        if current?.libraryID != opened.adoption.hostTrust.libraryID {
            try await replaceFromSnapshot(
                transport: opened.connection,
                authorization: authorization,
                libraryID: opened.adoption.hostTrust.libraryID
            )
        }
        try await applyChanges(
            transport: opened.connection,
            authorization: authorization,
            libraryID: opened.adoption.hostTrust.libraryID,
            mayRestartSnapshot: mayRestartSnapshot
        )
    }

    private func replaceFromSnapshot(
        transport: HarcPinnedGRPCConnection,
        authorization: HarcLibraryAuthorization,
        libraryID: LibraryID
    ) async throws {
        var begin = Harc_V1_BeginLibrarySnapshotRequestV1()
        begin.protocol = HarcProtocolVersion.v1.protobufV1()
        begin.preferredPageSize = 100
        let started = try await transport.beginLibrarySnapshot(
            begin,
            authorization: authorization
        )
        try Self.validateProtocol(started.hasProtocol, started.protocol)
        guard started.snapshotToken.count == 32 else {
            throw HarcMobileLibraryError.malformedResponse
        }

        var recordings: [LibraryRecordingSummary] = []
        var tombstones: [RecordingTombstone] = []
        var pageToken: Data?
        var seenPageTokens = Set<Data>()
        var pageCount = 0
        while true {
            pageCount += 1
            guard pageCount <= 2_000 else {
                throw HarcMobileLibraryError.malformedResponse
            }
            var request = Harc_V1_ListSnapshotPageRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.snapshotToken = started.snapshotToken
            if let pageToken { request.pageToken = pageToken }
            let page = try await transport.listSnapshotPage(
                request,
                authorization: authorization
            )
            try Self.validateProtocol(page.hasProtocol, page.protocol)
            guard page.snapshotAnchor == started.snapshotAnchor else {
                throw HarcMobileLibraryError.malformedResponse
            }
            for item in page.items {
                switch item.value {
                case .recording(let wire):
                    recordings.append(try wire.domainValue())
                case .tombstone(let wire):
                    tombstones.append(try wire.domainValue())
                case nil:
                    throw HarcMobileLibraryError.malformedResponse
                }
            }
            guard recordings.count + tombstones.count <= 100_000 else {
                throw HarcMobileLibraryError.malformedResponse
            }
            if page.complete {
                guard !page.hasNextPageToken else {
                    throw HarcMobileLibraryError.malformedResponse
                }
                break
            }
            guard page.hasNextPageToken,
                  !page.nextPageToken.isEmpty,
                  seenPageTokens.insert(page.nextPageToken).inserted else {
                throw HarcMobileLibraryError.malformedResponse
            }
            pageToken = page.nextPageToken
        }

        recordings.sort { $0.canonicalID < $1.canonicalID }
        tombstones.sort { $0.canonicalID < $1.canonicalID }
        let snapshot = try AnchoredLibrarySnapshot(
            libraryID: libraryID,
            anchor: ChangeCursor(started.snapshotAnchor),
            recordings: recordings,
            tombstones: tombstones
        )
        if started.hasRecordingCount {
            guard started.recordingCount == UInt64(recordings.count) else {
                throw HarcMobileLibraryError.malformedResponse
            }
        }
        if started.hasTombstoneCount {
            guard started.tombstoneCount == UInt64(tombstones.count) else {
                throw HarcMobileLibraryError.malformedResponse
            }
        }
        try cache.replace(with: snapshot)
    }

    private func applyChanges(
        transport: HarcPinnedGRPCConnection,
        authorization: HarcLibraryAuthorization,
        libraryID: LibraryID,
        mayRestartSnapshot: Bool
    ) async throws {
        var pages = 0
        while true {
            pages += 1
            guard pages <= 2_000 else {
                throw HarcMobileLibraryError.malformedResponse
            }
            let after = try cache.state()?.changeCursor ?? .zero
            var request = Harc_V1_ListChangesRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.afterCursor = after.rawValue
            request.limit = 500
            let response = try await transport.listLibraryChanges(
                request,
                authorization: authorization
            )
            try Self.validateProtocol(response.hasProtocol, response.protocol)
            switch response.disposition {
            case .listChangesDispositionFullResyncRequired:
                guard mayRestartSnapshot else {
                    throw HarcMobileLibraryError.repeatedFullResync
                }
                try await replaceFromSnapshot(
                    transport: transport,
                    authorization: authorization,
                    libraryID: libraryID
                )
                return try await applyChanges(
                    transport: transport,
                    authorization: authorization,
                    libraryID: libraryID,
                    mayRestartSnapshot: false
                )
            case .listChangesDispositionPage:
                var recordings: [LibraryRecordingSummary] = []
                var tombstones: [RecordingTombstone] = []
                var lastCursor = after
                for wire in response.changes {
                    let change = try wire.domainValue()
                    guard change.descriptor.cursor > lastCursor,
                          change.descriptor.cursor.rawValue
                            <= response.nextCursor else {
                        throw HarcMobileLibraryError.malformedResponse
                    }
                    lastCursor = change.descriptor.cursor
                    switch change.value {
                    case .upsert(let value): recordings.append(value)
                    case .tombstone(let value): tombstones.append(value)
                    }
                }
                let through = ChangeCursor(response.nextCursor)
                guard through >= lastCursor,
                      through >= after,
                      through > after || response.changes.isEmpty else {
                    throw HarcMobileLibraryError.malformedResponse
                }
                try cache.apply(
                    try ClientLibraryDelta(
                        libraryID: libraryID,
                        after: after,
                        through: through,
                        recordings: recordings,
                        tombstones: tombstones
                    )
                )
                if response.changes.isEmpty { return }
            case .listChangesDispositionUnspecified,
                 .UNRECOGNIZED(_):
                throw HarcMobileLibraryError.malformedResponse
            }
        }
    }

    private func loadCachedView() {
        do {
            recordings = try cache.recordings().sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt > $1.startedAt
                }
                return $0.canonicalID < $1.canonicalID
            }
        } catch {
            recordings = []
            state = .failed(error.localizedDescription)
        }
    }

    private static func validateProtocol(
        _ isPresent: Bool,
        _ wire: Harc_V1_ProtocolVersionV1
    ) throws {
        guard isPresent else {
            throw HarcMobileLibraryError.malformedResponse
        }
        let (version, _) = try HarcProtobufCompatibilityPolicy.currentV1
            .validate(wire, knownCriticalFieldNumbers: [1])
        guard version == .v1 else {
            throw HarcMobileLibraryError.malformedResponse
        }
    }
}

private enum HarcMobileLibraryError: LocalizedError {
    case accessNotGranted
    case malformedResponse
    case repeatedFullResync

    var errorDescription: String? {
        switch self {
        case .accessNotGranted:
            "This pairing does not grant Library access. Pair again and approve the requested Library scopes on the Host."
        case .malformedResponse:
            "The Host returned an invalid Library response."
        case .repeatedFullResync:
            "The Host Library changed too quickly to establish a stable cache."
        }
    }
}
