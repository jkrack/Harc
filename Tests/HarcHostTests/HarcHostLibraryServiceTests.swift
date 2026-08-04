import Foundation
import HarcDomain
import HarcIdentity
import HarcStore
import Testing
@testable import HarcHost

@Suite("Host canonical Library service")
struct HarcHostLibraryServiceTests {
    @Test("snapshot pages remain anchored while subsequent changes converge")
    func anchoredSnapshotAndDelta() async throws {
        let store = try await RecordingStore.inMemory()
        let first = try await store.upsert(recording(title: "Alpha", offset: 0))
        let second = try await store.upsert(recording(title: "Beta", offset: 1))
        let metadata = try await store.libraryMetadata()
        let session = try authenticatedSession(libraryID: metadata.libraryID)
        let service = HarcHostLibraryService(
            store: store,
            randomness: FixedLibraryRandomness()
        )

        let started = try await service.beginSnapshot(
            session: session,
            preferredPageSize: 1
        )
        let third = try await store.upsert(
            recording(title: "Gamma", offset: 2)
        )

        let pageOne = try await service.listSnapshotPage(
            session: session,
            snapshotToken: started.snapshotToken,
            pageToken: nil,
            maximumItems: 100
        )
        #expect(pageOne.items.count == 1)
        #expect(!pageOne.complete)
        let pageTwo = try await service.listSnapshotPage(
            session: session,
            snapshotToken: started.snapshotToken,
            pageToken: try #require(pageOne.nextPageToken),
            maximumItems: 100
        )
        #expect(pageTwo.items.count == 1)
        #expect(pageTwo.complete)
        let snapshotIDs = (pageOne.items + pageTwo.items).map(\.canonicalID)
        #expect(Set(snapshotIDs) == Set([first.canonicalID, second.canonicalID]))
        #expect(!snapshotIDs.contains(third.canonicalID))

        let changes = try await service.listChanges(
            session: session,
            after: started.anchor,
            limit: 100
        )
        guard case .page(let values, let nextCursor) = changes else {
            Issue.record("Expected a delta page")
            return
        }
        #expect(values.map(\.descriptor.canonicalID) == [third.canonicalID])
        #expect(nextCursor.rawValue == started.anchor.rawValue + 1)
    }

    @Test("metadata search pagination is stable and bound to its query")
    func metadataSearchPagination() async throws {
        let store = try await RecordingStore.inMemory()
        _ = try await store.upsert(recording(title: "Alpha", offset: 0))
        _ = try await store.upsert(recording(title: "Beta", offset: 1))
        _ = try await store.upsert(recording(title: "Gamma", offset: 2))
        let metadata = try await store.libraryMetadata()
        let session = try authenticatedSession(libraryID: metadata.libraryID)
        let service = HarcHostLibraryService(
            store: store,
            randomness: FixedLibraryRandomness()
        )
        let filter = HarcHostMetadataSearchFilter()

        let first = try await service.searchMetadata(
            session: session,
            filter: filter,
            sort: .startedAtAscending,
            limit: 1,
            pageToken: nil
        )
        #expect(first.recordings.map(\.title) == ["Alpha"])
        let token = try #require(first.nextPageToken)

        await #expect(throws: HarcHostLibraryError.invalidPageToken) {
            _ = try await service.searchMetadata(
                session: session,
                filter: filter,
                sort: .startedAtDescending,
                limit: 1,
                pageToken: token
            )
        }
    }

    @Test("lexical and hybrid transcript search return path-free hits")
    func transcriptSearch() async throws {
        let store = try await RecordingStore.inMemory()
        var launch = recording(title: "Launch", offset: 0)
        launch.transcriptText = "The launch checklist is ready for review."
        let stored = try await store.upsert(launch)
        _ = try await store.indexTranscript(
            recordingID: try #require(stored.id),
            text: try #require(stored.transcriptText),
            durationMs: 30_000,
            embedder: HashedLexicalEmbedder()
        )
        var unrelated = recording(title: "Lunch", offset: 1)
        unrelated.transcriptText = "We ordered sandwiches."
        _ = try await store.upsert(unrelated)

        let metadata = try await store.libraryMetadata()
        let session = try authenticatedSession(libraryID: metadata.libraryID)
        let service = HarcHostLibraryService(
            store: store,
            randomness: FixedLibraryRandomness()
        )
        for mode in [
            HarcHostTranscriptSearchMode.lexical,
            .semantic,
            .hybrid,
        ] {
            let page = try await service.searchTranscripts(
                session: session,
                query: "launch checklist",
                mode: mode,
                filter: HarcHostTranscriptSearchFilter(),
                limit: 10,
                pageToken: nil
            )
            #expect(page.hits.first?.recording.canonicalID == stored.canonicalID)
            #expect(page.hits.first?.snippets.isEmpty == false)
        }
    }

    private func recording(title: String, offset: TimeInterval) -> Recording {
        let started = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        return Recording(
            wavPath: "/tmp/\(title).wav",
            startedAt: started,
            endedAt: started.addingTimeInterval(30),
            title: title
        )
    }

    private func authenticatedSession(
        libraryID: LibraryID
    ) throws -> HostAuthenticatedSession {
        HostAuthenticatedSession(
            context: AuthenticatedDeviceContext(
                libraryID: libraryID,
                hostAuthorityID: try HostAuthorityID(
                    Data(repeating: 0x31, count: 32)
                ),
                authenticatedDeviceID: try DeviceID(
                    Data(repeating: 0x32, count: 32)
                ),
                grantID: GrantID(UUID()),
                grantEpoch: try GrantEpoch(1)
            ),
            scopes: [.libraryMetadataRead],
            exactCapabilitiesBytes: Data([0x01]),
            capabilitiesSHA256: Data(repeating: 0x33, count: 32),
            protocolMinor: 0,
            selectedCodec: "caf-alac",
            selectedContainer: "caf",
            expiresAt: Date().addingTimeInterval(600)
        )
    }
}

private struct FixedLibraryRandomness: HostAuthenticationRandomness {
    func randomBytes(count: Int) throws -> Data {
        Data(repeating: UInt8(count), count: count)
    }

    func randomUUID() throws -> UUID { UUID() }
}
