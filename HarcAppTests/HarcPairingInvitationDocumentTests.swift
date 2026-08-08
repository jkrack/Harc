import Foundation
import HarcProtocol
import Testing
@testable import Harc

@Suite("Pairing invitation document boundary")
struct HarcPairingInvitationDocumentTests {
    @Test("symlinks are rejected before reading invitation bytes")
    func rejectsSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not-a-ticket".utf8).write(to: fixture.regularFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.symlink,
            withDestinationURL: fixture.regularFile
        )

        #expect(throws: HarcPairingInvitationDocumentError.unsafeFile) {
            try HarcPairingInvitationDocument.load(from: fixture.symlink)
        }
    }

    @Test("oversized and non-file invitations fail closed")
    func rejectsUnsafeInputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(
            repeating: 0x41,
            count: PairingInvitationFileV1.maximumByteCount + 1
        ).write(to: fixture.regularFile)

        #expect(throws: HarcPairingInvitationDocumentError.unsafeFile) {
            try HarcPairingInvitationDocument.load(from: fixture.regularFile)
        }
        #expect(throws: HarcPairingInvitationDocumentError.unsafeFile) {
            try HarcPairingInvitationDocument.load(
                from: URL(string: "https://example.invalid/invite.harcpair")!
            )
        }
    }

    private struct Fixture {
        let root: URL
        let regularFile: URL
        let symlink: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "harc-pairing-document-\(UUID().uuidString)",
                isDirectory: true
            )
            regularFile = root.appendingPathComponent("invite.harcpair")
            symlink = root.appendingPathComponent("linked.harcpair")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
