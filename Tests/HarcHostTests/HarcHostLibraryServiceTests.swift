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
                grantEpoch: GrantEpoch(1)
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
