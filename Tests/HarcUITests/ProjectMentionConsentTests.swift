import Foundation
import Testing
import HarcDomain
@testable import HarcUI

@Suite("Project mention consent identity")
struct ProjectMentionConsentTests {
    @Test func identityChangesInvalidateTheApprovedKey() throws {
        let canonical = CanonicalRecordingID.random()
        let library = LibraryID.random()
        let authority = try HostAuthorityID(Data(repeating: 0x74, count: 32))
        let state = HostStateID.random()
        let project = UUID(), version = UUID()
        func key(canonicalID: CanonicalRecordingID? = nil, hostState: HostStateID? = nil,
                 projectVersion: UUID? = nil, libraryID: LibraryID? = nil) -> ProjectMentionConsentKey {
            ProjectMentionConsentKey(recordingID: 1, canonicalID: canonicalID ?? canonical,
                libraryID: libraryID ?? library, writerMode: .host, authority: authority,
                hostState: hostState ?? state, projectID: project, projectVersion: projectVersion ?? version)
        }
        let approved = key()
        #expect(approved == key())
        #expect(approved != key(canonicalID: .random()))
        #expect(approved != key(hostState: .random()))
        #expect(approved != key(projectVersion: UUID()))
        #expect(approved != key(libraryID: .random()))
    }

    @Test func lateInitialLoadCannotReplaceNewProjectList() {
        var generation = ProjectMentionLoadGeneration()
        let initialRead = generation.begin()
        _ = generation.begin() // creation invalidates the appearance read
        let afterCreateRead = generation.begin()
        #expect(generation.isCurrent(afterCreateRead))
        #expect(!generation.isCurrent(initialRead))
    }
}
