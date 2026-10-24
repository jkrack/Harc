import Foundation
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation

struct HarcLibraryAudioPolicy: Equatable, Sendable {
    let allowsDownload: Bool
    let retainsAfterPlayback: Bool

    init(allowsDownload: Bool, retainsAfterPlayback: Bool) {
        self.allowsDownload = allowsDownload
        self.retainsAfterPlayback = allowsDownload && retainsAfterPlayback
    }

    static let retainedDownloads = HarcLibraryAudioPolicy(
        allowsDownload: true,
        retainsAfterPlayback: true
    )
}

enum HarcMobileLibraryRefreshOperation: String, Sendable {
    case openingSession = "Host connection"
    case protectedEdits = "Protected edit sync"
    case metadata = "Library metadata refresh"
    case speakerProfiles = "Speaker profile update"
    case finishing = "Completing Host refresh"
}

enum HarcMobileLibraryRefreshPresentation {
    enum Action: Equatable { case refresh, setup }

    struct Status: Equatable {
        let title: String
        let detail: String
        let symbol: String
        let isLoading: Bool
        let action: Action?
    }

    /// Both Library surfaces consume the coordinator's app-owned, sanitized state.
    static func status(_ state: HarcMobileLibraryCoordinator.State, hasRows: Bool) -> Status {
        switch state {
        case .loadingCache:
            Status(title: "Opening Mac Library…", detail: "Opening the protected Library cache.",
                   symbol: "rectangle.stack", isLoading: true, action: nil)
        case .refreshing:
            Status(title: "Refreshing Mac Library…",
                   detail: hasRows ? "Your saved recordings are still available." : "Checking your Mac for recordings.",
                   symbol: "arrow.clockwise", isLoading: true, action: nil)
        case .unpaired:
            Status(title: "Pair a Mac for its Library",
                   detail: "Recordings saved on this iPhone appear here, even without a Mac.",
                   symbol: "desktopcomputer", isLoading: false, action: .setup)
        case .accessNotGranted:
            Status(title: "Mac Library access not granted",
                   detail: "Your Mac has not granted Library access. Check Setup & Sync and the invitation permissions on your Mac.",
                   symbol: "lock", isLoading: false, action: .setup)
        case .cancelled:
            Status(title: "Library refresh cancelled",
                   detail: hasRows ? "Your saved recordings are still available. Refresh when you’re ready."
                       : "The Mac Library has not been checked. Refresh when you’re ready.",
                   symbol: "arrow.clockwise", isLoading: false, action: .refresh)
        case .offline(let message), .failed(let message):
            Status(title: "Couldn’t refresh Mac Library", detail: message,
                   symbol: "exclamationmark.triangle", isLoading: false, action: .refresh)
        case .ready:
            Status(title: hasRows ? "Mac Library updated" : "No recordings yet",
                   detail: hasRows ? "Showing the saved Mac Library."
                       : "Your Mac Library has no recordings. Recordings saved on this iPhone appear here, even without a Mac.",
                   symbol: "rectangle.stack", isLoading: false, action: .refresh)
        }
    }

    static func failureMessage(
        _ error: any Error,
        operation: HarcMobileLibraryRefreshOperation,
        hasCachedRows: Bool
    ) -> String {
        // RPC messages, localized descriptions, and nested causes are untrusted:
        // they can contain credentials or user content. Only expose the typed
        // status and fixed app-owned labels or allowlisted repair guidance.
        let detail: String
        if let connectorError = error as? HarcMobileHostSessionConnectorError,
           case .pairingRepairRequired = connectorError {
            detail = HarcMobileHostSessionConnectorError.pairingRepairGuidance
        } else {
            let status = HarcTransportErrorDiagnostic.describe(error).rpcCode
            detail = status.map { "Host request failed (\($0))." }
                ?? "Host request failed."
        }
        let prefix = hasCachedRows ? "Showing cached Host Library. " : ""
        return "\(prefix)\(operation.rawValue): \(detail)"
    }
}

/// The refresh lifecycle accepts an opened session so its stage ordering and
/// cancellation ownership can be exercised without real credentials or sockets.
/// Production sessions are always opened by the authenticated Host connector.
@MainActor
struct HarcMobileLibraryRefreshSession {
    typealias Operation = @MainActor () async throws -> Void
    typealias Opener = @MainActor () async throws -> Self

    let protectedEdits: Operation?
    /// Absent when the adopted grant does not allow metadata reads.
    let metadata: Operation?
    let speakerProfiles: Operation?
    let finish: Operation
    let abort: @MainActor () async -> Void
}

@MainActor
@Observable
final class HarcMobileLibraryCoordinator {
    struct SearchResult: Identifiable, Equatable {
        let recording: LibraryRecordingSummary
        let score: Double?
        let snippets: [String]
        let matchSpeakerIndex: UInt32?
        let matchTimestamp: TimeInterval?

        var id: CanonicalRecordingID { recording.canonicalID }
    }

    enum State: Equatable {
        case loadingCache
        case unpaired
        case accessNotGranted
        case refreshing
        case cancelled
        case ready(lastUpdated: Date?)
        case offline(message: String)
        case failed(String)
    }

    enum MutationSubmissionOutcome: Equatable {
        case applied
        case queuedOffline
        case conflict
    }

    private(set) var state: State = .loadingCache
    private(set) var recordings: [LibraryRecordingSummary] = []
    private(set) var isRefreshing = false
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var searchMessage: String?
    private(set) var pendingMutationCount = 0
    private(set) var conflicts: [VisibleLibraryConflict] = []
    private(set) var lastUpdatedAt: Date?
    private(set) var recognitionPack: SpeakerRecognitionPack?
    private(set) var audioPolicy: HarcLibraryAudioPolicy

    private let identity: InstallationSigningIdentity
    private let transferStore: HarcTransferStore
    private let cache: HarcLibraryCache
    private let routeURL: URL
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private let refreshSessionOpener: HarcMobileLibraryRefreshSession.Opener?
    private var activeSearchID: UUID?

    init(
        identity: InstallationSigningIdentity,
        transferStore: HarcTransferStore,
        cache: HarcLibraryCache,
        routeURL: URL,
        audioPolicy: HarcLibraryAudioPolicy = .retainedDownloads,
        refreshSessionOpener: HarcMobileLibraryRefreshSession.Opener? = nil
    ) {
        self.identity = identity
        self.transferStore = transferStore
        self.cache = cache
        self.routeURL = routeURL
        self.audioPolicy = audioPolicy
        self.refreshSessionOpener = refreshSessionOpener
        loadCachedView()
    }

    func applyAudioPolicy(_ policy: HarcLibraryAudioPolicy) throws {
        audioPolicy = policy
        if !policy.allowsDownload || !policy.retainsAfterPlayback {
            try clearDownloadedAudio()
        }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        isRefreshing = true
        state = .refreshing
        refreshTask = Task { [weak self] in
            await self?.performRefresh(id: refreshID)
        }
    }

    func shutdown() {
        if isRefreshing { state = .cancelled }
        activeRefreshID = nil
        refreshTask?.cancel()
        refreshTask = nil
        activeSearchID = nil
        isRefreshing = false
        isSearching = false
    }

    func submitMetadataMutation(
        summary: LibraryRecordingSummary,
        mutation: HarcMobileMetadataMutation
    ) async throws -> MutationSubmissionOutcome {
        guard let snapshot = try transferStore.activeAdoption() else {
            throw HarcMobileHostSessionConnectorError.notPaired
        }
        let adoption = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: identity.publicKey
        )
        guard adoption.grant.scopes.contains(.libraryMetadataWrite) else {
            throw HarcMobileLibraryError.accessNotGranted
        }
        if case .assignSpeakerIdentity = mutation,
           !adoption.grant.scopes.contains(.speakerAssignmentWrite) {
            throw HarcMobileLibraryError.accessNotGranted
        }
        let signed = try HarcMobileSignedMetadataMutation(
            mutation: mutation,
            summary: summary,
            adoption: adoption,
            identity: identity
        )
        try cache.persistOfflineMutation(signed.queued)
        loadQueueView()

        do {
            let opened = try await HarcMobileHostSessionConnector.open(
                identity: identity,
                store: transferStore,
                routeURL: routeURL
            )
            do {
                let authorization = try HarcLibraryAuthorization(
                    openedSession: opened.session
                )
                try await drainOfflineMutations(
                    opened: opened,
                    authorization: authorization
                )
                try await synchronize(
                    opened: opened,
                    authorization: authorization,
                    mayRestartSnapshot: true
                )
                try await opened.connection.shutdownGracefully()
                loadCachedView()
                let conflicted = conflicts.contains {
                    $0.operationID == signed.queued.operationID
                }
                return conflicted ? .conflict : .applied
            } catch {
                await opened.connection.shutdownImmediately()
                throw error
            }
        } catch {
            loadQueueView()
            if conflicts.contains(where: {
                $0.operationID == signed.queued.operationID
            }) {
                return .conflict
            }
            if !(try cache.offlineMutations()).contains(where: {
                $0.operationID == signed.queued.operationID
            }) {
                // The Host committed and acknowledged this operation; only
                // the follow-up cache synchronization failed.
                return .applied
            }
            state = .offline(
                message: "Your edit is protected on this client and will retry when the Host is reachable."
            )
            return .queuedOffline
        }
    }

    func acceptHostValue(for conflict: VisibleLibraryConflict) throws {
        try cache.resolveConflict(conflict.conflictID)
        if let operationID = conflict.operationID {
            try cache.updateOfflineMutationState(
                operationID: operationID,
                state: .completed
            )
        }
        loadQueueView()
    }

    func clearDownloadedAudio() throws {
        let parent = cache.databaseURL.deletingLastPathComponent()
            .standardizedFileURL
        let audio = parent.appendingPathComponent(
            "Audio",
            isDirectory: true
        ).standardizedFileURL
        guard audio.deletingLastPathComponent() == parent else {
            throw HarcMobileLibraryError.malformedResponse
        }
        if FileManager.default.fileExists(atPath: audio.path) {
            try FileManager.default.removeItem(at: audio)
        }
    }

    func resetLibraryCache() throws {
        try cache.clearCachedLibraryProjection()
        loadCachedView()
        refresh()
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
            try Self.validateLibraryProtocol(
                response.hasProtocol,
                response.protocol
            )
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

    func submitSpeakerObservation(
        _ observation: SpeakerEmbeddingObservation
    ) async throws -> SpeakerObservationDecision {
        let opened = try await HarcMobileHostSessionConnector.open(
            identity: identity,
            store: transferStore,
            routeURL: routeURL
        )
        do {
            guard opened.adoption.grant.scopes.contains(
                .speakerObservationWrite
            ) else {
                throw HarcMobileLibraryError.accessNotGranted
            }
            let authorization = try HarcLibraryAuthorization(
                openedSession: opened.session
            )
            var request = Harc_V1_SubmitSpeakerObservationRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.observation = Harc_V1_SpeakerEmbeddingObservationV1(
                observation
            )
            let response = try await opened.connection
                .submitSpeakerObservation(
                    request,
                    authorization: authorization
                )
            try Self.validateLibraryProtocol(
                response.hasProtocol,
                response.protocol
            )
            guard response.hasDecision else {
                throw HarcMobileLibraryError.malformedResponse
            }
            let decision = try response.decision.domainValue()
            guard decision.operationID == observation.operationID else {
                throw HarcMobileLibraryError.malformedResponse
            }
            if opened.adoption.grant.scopes.contains(.speakerIdentityRead) {
                try await refreshRecognitionPack(
                    opened: opened,
                    authorization: authorization
                )
            }
            try await opened.connection.shutdownGracefully()
            return decision
        } catch {
            await opened.connection.shutdownImmediately()
            throw error
        }
    }

    func downloadCanonicalAudio(
        summary: LibraryRecordingSummary
    ) async throws -> URL {
        guard audioPolicy.allowsDownload else {
            throw HarcMobileLibraryAudioError.downloadsDisabled
        }
        guard summary.canonicalAudio.availability == .available else {
            throw HarcMobileLibraryAudioError.malformedStream
        }
        let localCache = cache
        let paths = try await Task.detached(priority: .userInitiated) {
            try HarcMobileAudioCachePaths(cache: localCache, summary: summary)
        }.value
        let cached = try await Task.detached(priority: .userInitiated) {
            try paths.validatedCachedURL(summary: summary)
        }.value
        if let cached {
            return cached
        }
        let resumeOffset = try await Task.detached(priority: .userInitiated) {
            try paths.boundedResumeOffset(summary: summary)
        }.value
        let sink = try await Task.detached(priority: .userInitiated) {
            try HarcMobileAudioDownloadSink(
                paths: paths,
                summary: summary,
                resumeOffset: resumeOffset
            )
        }.value
        let opened = try await HarcMobileHostSessionConnector.open(
            identity: identity,
            store: transferStore,
            routeURL: routeURL
        )
        do {
            var request = Harc_V1_GetAudioRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.canonicalRecordingID =
                Harc_V1_CanonicalRecordingIDV1(summary.canonicalID)
            request.expectedRevision = summary.revision.rawValue
            request.representation = .audioRepresentationCanonicalWav
            if resumeOffset > 0 { request.resumeByteOffset = resumeOffset }
            try await opened.connection.getLibraryAudio(
                request,
                authorization: try HarcLibraryAuthorization(
                    openedSession: opened.session
                ),
                responseConsumer: { response in
                    try await sink.consume(response)
                }
            )
            let final = try await sink.finish()
            try await opened.connection.shutdownGracefully()
            return final
        } catch {
            await opened.connection.shutdownImmediately()
            if error is HarcMobileLibraryAudioError {
                await sink.discardUnverifiedPartial()
            }
            throw error
        }
    }

    func releaseDownloadedAudio(
        summary: LibraryRecordingSummary
    ) async throws {
        guard !audioPolicy.retainsAfterPlayback else { return }
        let localCache = cache
        try await Task.detached(priority: .utility) {
            let paths = try HarcMobileAudioCachePaths(
                cache: localCache,
                summary: summary
            )
            try paths.removeCachedFiles()
        }.value
    }

    func search(_ rawQuery: String) async {
        let searchID = UUID()
        activeSearchID = searchID
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchMessage = nil
            isSearching = false
            activeSearchID = nil
            return
        }
        guard query.utf8.count <= 1_024 else {
            searchResults = []
            searchMessage = "Search is limited to 1,024 UTF-8 bytes."
            isSearching = false
            activeSearchID = nil
            return
        }
        isSearching = true
        searchMessage = nil
        defer {
            if activeSearchID == searchID {
                isSearching = false
                activeSearchID = nil
            }
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
                    throw HarcMobileLibraryError.accessNotGranted
                }
                let authorization = try HarcLibraryAuthorization(
                    openedSession: opened.session
                )
                let metadata = try await searchMetadata(
                    query: query,
                    transport: opened.connection,
                    authorization: authorization
                )
                let transcripts: [SearchResult]
                if opened.adoption.grant.scopes.contains(
                    .libraryTranscriptRead
                ) {
                    transcripts = try await searchTranscripts(
                        query: query,
                        transport: opened.connection,
                        authorization: authorization
                    )
                } else {
                    transcripts = []
                }
                try await opened.connection.shutdownGracefully()
                guard !Task.isCancelled,
                      activeSearchID == searchID else { return }
                var seen = Set<CanonicalRecordingID>()
                searchResults = (transcripts + metadata).filter {
                    seen.insert($0.id).inserted
                }
            } catch {
                await opened.connection.shutdownImmediately()
                throw error
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  activeSearchID == searchID else { return }
            searchResults = localMetadataSearch(query)
            searchMessage = searchResults.isEmpty
                ? error.localizedDescription
                : "Host search is offline; showing cached title and tag matches."
        }
    }

    private func performRefresh(id: UUID) async {
        defer {
            // A cancelled request may finish after shutdown and another refresh.
            // It owns neither the new task handle nor its visible progress.
            if activeRefreshID == id {
                isRefreshing = false
                refreshTask = nil
                activeRefreshID = nil
            }
        }
        var operation = HarcMobileLibraryRefreshOperation.openingSession
        do {
            try checkCurrentRefresh(id)
            let session = try await openRefreshSession()
            do {
                try checkCurrentRefresh(id)
                guard let metadata = session.metadata else {
                    state = .accessNotGranted
                    try await session.finish()
                    try checkCurrentRefresh(id)
                    return
                }
                if let protectedEdits = session.protectedEdits {
                    operation = .protectedEdits
                    try await protectedEdits()
                    try checkCurrentRefresh(id)
                }
                operation = .metadata
                try await metadata()
                try checkCurrentRefresh(id)
                if let speakerProfiles = session.speakerProfiles {
                    operation = .speakerProfiles
                    try await speakerProfiles()
                    try checkCurrentRefresh(id)
                }
                operation = .finishing
                try await session.finish()
                try checkCurrentRefresh(id)
                loadCachedView()
                state = .ready(lastUpdated: try cache.state()?.updatedAt)
            } catch {
                await session.abort()
                throw error
            }
        } catch HarcMobileHostSessionConnectorError.notPaired {
            guard activeRefreshID == id, !Task.isCancelled else { return }
            state = recordings.isEmpty ? .unpaired : .offline(
                message: "Showing the protected local cache. Pair a Host to refresh."
            )
        } catch {
            guard activeRefreshID == id, !Task.isCancelled else { return }
            loadCachedView()
            let message = HarcMobileLibraryRefreshPresentation.failureMessage(
                error,
                operation: operation,
                hasCachedRows: !recordings.isEmpty
            )
            state = recordings.isEmpty
                ? .failed(message)
                : .offline(message: message)
        }
    }

    private func checkCurrentRefresh(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeRefreshID == id else { throw CancellationError() }
    }

    private func openRefreshSession() async throws -> HarcMobileLibraryRefreshSession {
        if let refreshSessionOpener { return try await refreshSessionOpener() }
        let opened = try await HarcMobileHostSessionConnector.open(
            identity: identity, store: transferStore, routeURL: routeURL
        )
        let finish: HarcMobileLibraryRefreshSession.Operation = {
            try await opened.connection.shutdownGracefully()
        }
        let abort: @MainActor () async -> Void = {
            await opened.connection.shutdownImmediately()
        }
        guard opened.adoption.grant.scopes.contains(.libraryMetadataRead) else {
            return HarcMobileLibraryRefreshSession(
                protectedEdits: nil, metadata: nil, speakerProfiles: nil,
                finish: finish, abort: abort
            )
        }
        do {
            let authorization = try HarcLibraryAuthorization(
                openedSession: opened.session
            )
            let protectedEdits: HarcMobileLibraryRefreshSession.Operation?
            if opened.adoption.grant.scopes.contains(.libraryMetadataWrite) {
                protectedEdits = {
                    try await self.drainOfflineMutations(
                        opened: opened, authorization: authorization
                    )
                }
            } else {
                protectedEdits = nil
            }
            let speakerProfiles: HarcMobileLibraryRefreshSession.Operation?
            if opened.adoption.grant.scopes.contains(.speakerIdentityRead) {
                speakerProfiles = {
                    try await self.refreshRecognitionPack(
                        opened: opened, authorization: authorization
                    )
                }
            } else {
                speakerProfiles = nil
            }
            return HarcMobileLibraryRefreshSession(
                protectedEdits: protectedEdits,
                metadata: {
                    try await self.synchronize(
                        opened: opened, authorization: authorization,
                        mayRestartSnapshot: true, includeSpeakerProfiles: false
                    )
                },
                speakerProfiles: speakerProfiles, finish: finish, abort: abort
            )
        } catch {
            await abort()
            throw error
        }
    }

    private func searchMetadata(
        query: String,
        transport: HarcPinnedGRPCConnection,
        authorization: HarcLibraryAuthorization
    ) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        var pageToken: Data?
        var seenTokens = Set<Data>()
        for _ in 0 ..< 20 {
            var filter = Harc_V1_MetadataSearchFilterV1()
            filter.titleContains = query
            var request = Harc_V1_SearchMetadataRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.filter = filter
            request.sort = .metadataSearchSortStartedAtDescending
            request.limit = 50
            if let pageToken { request.pageToken = pageToken }
            let response = try await transport.searchLibraryMetadata(
                request,
                authorization: authorization
            )
            try Self.validateLibraryProtocol(
                response.hasProtocol,
                response.protocol
            )
            results.append(contentsOf: try response.recordings.map {
                SearchResult(
                    recording: try $0.domainValue(),
                    score: nil,
                    snippets: [],
                    matchSpeakerIndex: nil,
                    matchTimestamp: nil
                )
            })
            guard response.hasNextPageToken else { return results }
            guard response.nextPageToken.count == 24,
                  seenTokens.insert(response.nextPageToken).inserted else {
                throw HarcMobileLibraryError.malformedResponse
            }
            pageToken = response.nextPageToken
        }
        throw HarcMobileLibraryError.malformedResponse
    }

    private func searchTranscripts(
        query: String,
        transport: HarcPinnedGRPCConnection,
        authorization: HarcLibraryAuthorization
    ) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        var pageToken: Data?
        var seenTokens = Set<Data>()
        for _ in 0 ..< 20 {
            var request = Harc_V1_SearchTranscriptsRequestV1()
            request.protocol = HarcProtocolVersion.v1.protobufV1()
            request.query = query
            request.mode = .transcriptSearchModeHybrid
            request.filter = Harc_V1_TranscriptSearchFilterV1()
            request.limit = 50
            if let pageToken { request.pageToken = pageToken }
            let response = try await transport.searchLibraryTranscripts(
                request,
                authorization: authorization
            )
            try Self.validateLibraryProtocol(
                response.hasProtocol,
                response.protocol
            )
            for hit in response.hits {
                guard hit.hasRecording, hit.score.isFinite else {
                    throw HarcMobileLibraryError.malformedResponse
                }
                let recording = try hit.recording.domainValue()
                var matchTimestamp: TimeInterval?
                for (index, snippet) in hit.snippets.enumerated() {
                    guard snippet.hasFrames else {
                        throw HarcMobileLibraryError.malformedResponse
                    }
                    let frames = try snippet.frames.domainValue()
                    if index == 0 {
                        let sampleRate = recording.canonicalAudio.format?
                            .sampleRateHz
                            ?? CanonicalPCMFormat.harcV1.sampleRateHz
                        matchTimestamp = TimeInterval(frames.startFrame)
                            / TimeInterval(sampleRate)
                    }
                }
                results.append(
                    SearchResult(
                        recording: recording,
                        score: hit.score,
                        snippets: hit.snippets.map(\.text),
                        matchSpeakerIndex: hit.snippets.first.flatMap {
                            $0.hasSpeakerIndex ? $0.speakerIndex : nil
                        },
                        matchTimestamp: matchTimestamp
                    )
                )
            }
            guard response.hasNextPageToken else { return results }
            guard response.nextPageToken.count == 24,
                  seenTokens.insert(response.nextPageToken).inserted else {
                throw HarcMobileLibraryError.malformedResponse
            }
            pageToken = response.nextPageToken
        }
        throw HarcMobileLibraryError.malformedResponse
    }

    private func localMetadataSearch(_ query: String) -> [SearchResult] {
        recordings.filter { recording in
            (recording.title ?? recording.suggestedTitle ?? "")
                .localizedCaseInsensitiveContains(query)
                || recording.tags.contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }.map {
            SearchResult(
                recording: $0,
                score: nil,
                snippets: [],
                matchSpeakerIndex: nil,
                matchTimestamp: nil
            )
        }
    }

    private func synchronize(
        opened: HarcMobileOpenedHostConnection,
        authorization: HarcLibraryAuthorization,
        mayRestartSnapshot: Bool,
        includeSpeakerProfiles: Bool = true
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
        if includeSpeakerProfiles,
           opened.adoption.grant.scopes.contains(.speakerIdentityRead) {
            try await refreshRecognitionPack(
                opened: opened,
                authorization: authorization
            )
        }
    }

    private func refreshRecognitionPack(
        opened: HarcMobileOpenedHostConnection,
        authorization: HarcLibraryAuthorization
    ) async throws {
        let libraryID = opened.adoption.hostTrust.libraryID
        let cached = try cache.speakerRecognitionPack(libraryID: libraryID)
        var request = Harc_V1_GetSpeakerRecognitionPackRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        if let cached { request.afterRevision = cached.revision.rawValue }
        let response = try await opened.connection.getSpeakerRecognitionPack(
            request,
            authorization: authorization
        )
        try Task.checkCancellation()
        try Self.validateLibraryProtocol(
            response.hasProtocol,
            response.protocol
        )
        guard response.unchanged != response.hasPack else {
            throw HarcMobileLibraryError.malformedResponse
        }
        if response.unchanged {
            recognitionPack = cached
            return
        }
        let pack = try response.pack.domainValue()
        try cache.persistSpeakerRecognitionPack(pack, libraryID: libraryID)
        recognitionPack = pack
    }

    private func drainOfflineMutations(
        opened: HarcMobileOpenedHostConnection,
        authorization: HarcLibraryAuthorization
    ) async throws {
        guard opened.adoption.grant.scopes.contains(
            .libraryMetadataWrite
        ) else { return }
        for queued in try cache.offlineMutations() {
            guard queued.libraryID == opened.adoption.grant.libraryID else {
                throw HarcMobileLibraryError.malformedResponse
            }
            guard queued.state == .queued || queued.state == .sending else {
                continue
            }
            try cache.updateOfflineMutationState(
                operationID: queued.operationID,
                state: .sending
            )
            do {
                let response = try await opened.connection
                    .applyLibraryMetadataMutation(
                        HarcMobileSignedMetadataMutation.request(for: queued),
                        authorization: authorization
                    )
                try Self.validateLibraryProtocol(
                    response.hasProtocol,
                    response.protocol
                )
                switch response.result {
                case .applied(let applied):
                    guard applied.newRevision >= queued.expectedRevision.rawValue,
                          applied.changeCursor > 0 else {
                        throw HarcMobileLibraryError.malformedResponse
                    }
                    try cache.updateOfflineMutationState(
                        operationID: queued.operationID,
                        state: .completed
                    )
                case .conflict(let conflict):
                    guard conflict.currentRevision > 0,
                          conflict.hasCurrentValue else {
                        throw HarcMobileLibraryError.malformedResponse
                    }
                    let current = try await fetchRecordingSummary(
                        canonicalID: queued.canonicalRecordingID,
                        transport: opened.connection,
                        authorization: authorization
                    )
                    guard current.revision.rawValue
                            >= conflict.currentRevision else {
                        throw HarcMobileLibraryError.malformedResponse
                    }
                    try cache.recordConflict(
                        try VisibleLibraryConflict(
                            operationID: queued.operationID,
                            libraryID: queued.libraryID,
                            canonicalRecordingID: queued.canonicalRecordingID,
                            expectedRevision: queued.expectedRevision,
                            currentRevision: current.revision,
                            currentValue: current,
                            createdAt: Date()
                        )
                    )
                case nil:
                    throw HarcMobileLibraryError.malformedResponse
                }
            } catch {
                if (try? cache.offlineMutations().first(where: {
                    $0.operationID == queued.operationID
                })?.state) == .sending {
                    try? cache.updateOfflineMutationState(
                        operationID: queued.operationID,
                        state: .queued
                    )
                }
                throw error
            }
        }
        loadQueueView()
    }

    private func fetchRecordingSummary(
        canonicalID: CanonicalRecordingID,
        transport: HarcPinnedGRPCConnection,
        authorization: HarcLibraryAuthorization
    ) async throws -> LibraryRecordingSummary {
        var request = Harc_V1_GetRecordingRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            canonicalID
        )
        request.requestedFields = [.recordingDetailFieldMetadata]
        let response = try await transport.getLibraryRecording(
            request,
            authorization: authorization
        )
        try Self.validateLibraryProtocol(response.hasProtocol, response.protocol)
        guard response.hasRecording else {
            throw HarcMobileLibraryError.malformedResponse
        }
        let detail = try response.recording.domainValue()
        guard detail.summary.canonicalID == canonicalID else {
            throw HarcMobileLibraryError.malformedResponse
        }
        return detail.summary
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
        try Task.checkCancellation()
        try Self.validateLibraryProtocol(started.hasProtocol, started.protocol)
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
            try Task.checkCancellation()
            try Self.validateLibraryProtocol(page.hasProtocol, page.protocol)
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
            try Task.checkCancellation()
            try Self.validateLibraryProtocol(
                response.hasProtocol,
                response.protocol
            )
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
            let cacheState = try cache.state()
            lastUpdatedAt = cacheState?.updatedAt
            recordings = try cache.recordings().sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt > $1.startedAt
                }
                return $0.canonicalID < $1.canonicalID
            }
            if let libraryID = cacheState?.libraryID {
                recognitionPack = try cache.speakerRecognitionPack(
                    libraryID: libraryID
                )
            } else {
                recognitionPack = nil
            }
            loadQueueView()
        } catch {
            recordings = []
            lastUpdatedAt = nil
            state = .failed("Protected Library cache could not be read.")
        }
    }

    private func loadQueueView() {
        do {
            let mutations = try cache.offlineMutations()
            pendingMutationCount = mutations.filter {
                $0.state == .queued || $0.state == .sending
            }.count
            conflicts = try cache.conflicts()
        } catch {
            pendingMutationCount = 0
            conflicts = []
        }
    }

    nonisolated static func validateLibraryProtocol(
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

enum HarcMobileLibraryError: LocalizedError {
    case accessNotGranted
    case invalidMetadataValue
    case malformedResponse
    case repeatedFullResync

    var errorDescription: String? {
        switch self {
        case .accessNotGranted:
            "This pairing does not grant Library access. Pair again and approve the requested Library scopes on the Host."
        case .invalidMetadataValue:
            "Metadata values cannot be empty. Clear the field explicitly instead."
        case .malformedResponse:
            "The Host returned an invalid Library response."
        case .repeatedFullResync:
            "The Host Library changed too quickly to establish a stable cache."
        }
    }
}
