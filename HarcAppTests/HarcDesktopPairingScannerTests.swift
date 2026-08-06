@preconcurrency import AVFoundation
import Testing
@testable import Harc

@Suite("Desktop pairing QR scanner")
struct HarcDesktopPairingScannerTests {
    @Test("accepts only bounded canonical v1 QR candidates")
    func candidateFilter() {
        #expect(HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/ABC_123-xyz"))
        #expect(!HarcDesktopPairingCodeFilter.accepts(""))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v2/ABC"))
        #expect(!HarcDesktopPairingCodeFilter.accepts(" harc-pair://v1/ABC"))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/ABC\n"))
        #expect(!HarcDesktopPairingCodeFilter.accepts("harc-pair://v1/café"))
    }

    @Test("rejects payloads above the frozen QR byte limit")
    func byteLimit() {
        let prefix = HarcDesktopPairingCodeFilter.prefix
        let accepted = prefix + String(
            repeating: "A",
            count: HarcDesktopPairingCodeFilter.maximumUTF8ByteCount
                - prefix.utf8.count
        )
        #expect(HarcDesktopPairingCodeFilter.accepts(accepted))
        #expect(!HarcDesktopPairingCodeFilter.accepts(accepted + "A"))
    }

    @Test("normalizes only surrounding pasteboard whitespace")
    func pastedCandidate() {
        let link = "harc-pair://v1/ABC_123-xyz"
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(" \n\(link)\t")
                == link
        )
        #expect(HarcDesktopPairingCodeFilter.pastedCandidate(nil) == nil)
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(
                "harc-pair://v1/ABC 123"
            ) == nil
        )
        #expect(
            HarcDesktopPairingCodeFilter.pastedCandidate(
                "not-a-harc-link"
            ) == nil
        )
    }

    @Test("configures QR only after the attached output reports support")
    func metadataCapabilityPolicy() {
        #expect(
            HarcDesktopPairingMetadataPolicy.qrObjectTypes(
                availableTypes: []
            ) == nil
        )
        #expect(
            HarcDesktopPairingMetadataPolicy.qrObjectTypes(
                availableTypes: [.face]
            ) == nil
        )
        #expect(
            HarcDesktopPairingMetadataPolicy.qrObjectTypes(
                availableTypes: [.face, .qr]
            ) == [.qr]
        )
    }
}
