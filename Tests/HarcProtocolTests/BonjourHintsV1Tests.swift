import HarcProtocol
import Testing

@Suite("Bonjour V1 hints")
struct BonjourHintsV1Tests {
    @Test("canonical TXT record round trips every allowed nonsecret hint")
    func canonicalRoundTrip() throws {
        let hints = try HarcBonjourServiceHintsV1(
            displayName: "Studio Host",
            protocolMajor: 1,
            protocolMinor: 0,
            capabilityBits: 0x8000_0000_0000_0005,
            uploadPortHint: 8_444
        )

        #expect(hints.txtRecord == [
            "dn": "Studio Host",
            "pmaj": "1",
            "pmin": "0",
            "caps": "8000000000000005",
            "uport": "8444",
        ])
        #expect(try HarcBonjourServiceHintsV1(txtRecord: hints.txtRecord) == hints)
    }

    @Test("unknown and missing TXT fields fail closed")
    func closedFieldSet() {
        let canonical = [
            "dn": "Host",
            "pmaj": "1",
            "pmin": "0",
            "caps": "0000000000000000",
        ]
        var unknown = canonical
        unknown["authority"] = "not-allowed"
        #expect(throws: HarcBonjourHintsV1Error.unknownTXTKey("authority")) {
            try HarcBonjourServiceHintsV1(txtRecord: unknown)
        }

        var missing = canonical
        missing.removeValue(forKey: "caps")
        #expect(throws: HarcBonjourHintsV1Error.missingTXTKey("caps")) {
            try HarcBonjourServiceHintsV1(txtRecord: missing)
        }
    }

    @Test("numeric values require shortest canonical encodings")
    func canonicalNumbers() {
        var record = [
            "dn": "Host",
            "pmaj": "01",
            "pmin": "0",
            "caps": "0000000000000000",
        ]
        #expect(throws: HarcBonjourHintsV1Error.invalidProtocolMajor) {
            try HarcBonjourServiceHintsV1(txtRecord: record)
        }

        record["pmaj"] = "1"
        record["caps"] = "000000000000000A"
        #expect(throws: HarcBonjourHintsV1Error.invalidCapabilityBits) {
            try HarcBonjourServiceHintsV1(txtRecord: record)
        }

        record["caps"] = "000000000000000a"
        record["uport"] = "0"
        #expect(throws: HarcBonjourHintsV1Error.invalidUploadPort) {
            try HarcBonjourServiceHintsV1(txtRecord: record)
        }
    }

    @Test("display names are bounded canonical DNS-SD text")
    func displayNameValidation() {
        #expect(throws: HarcBonjourHintsV1Error.invalidDisplayName) {
            try HarcBonjourServiceHintsV1(
                displayName: " Host",
                protocolMajor: 1,
                protocolMinor: 0,
                capabilityBits: 0
            )
        }
        #expect(throws: HarcBonjourHintsV1Error.invalidDisplayName) {
            try HarcBonjourServiceHintsV1(
                displayName: String(repeating: "a", count: 64),
                protocolMajor: 1,
                protocolMinor: 0,
                capabilityBits: 0
            )
        }
    }
}
