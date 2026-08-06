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
}
