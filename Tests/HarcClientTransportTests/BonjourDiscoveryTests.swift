#if canImport(Network)
import HarcProtocol
@testable import HarcClientTransport
import Network
import Testing

@Suite("Bonjour discovery")
struct BonjourDiscoveryTests {
    @Test("parser preserves an untrusted service endpoint and strict hints")
    func parsesCandidate() throws {
        let hints = try makeHints()
        let endpoint = NWEndpoint.service(
            name: "Studio Host",
            type: HarcBonjourServiceHintsV1.serviceType,
            domain: "local.",
            interface: nil
        )

        let candidate = try HarcBonjourDiscoveryParserV1.parse(
            endpoint: endpoint,
            txtRecord: NWTXTRecord(hints.txtRecord)
        )

        #expect(candidate.endpoint == endpoint)
        #expect(candidate.serviceName == "Studio Host")
        #expect(candidate.domain == "local.")
        #expect(candidate.hints == hints)
        #expect(candidate.hints.uploadPortHint == 8_444)
    }

    @Test("non-Bonjour endpoints and wrong service types fail closed")
    func rejectsWrongEndpoint() throws {
        let txt = NWTXTRecord(try makeHints().txtRecord)
        #expect(throws:
            HarcBonjourDiscoveryParseError.endpointIsNotBonjourService
        ) {
            try HarcBonjourDiscoveryParserV1.parse(
                endpoint: .hostPort(host: "host.local", port: 8_443),
                txtRecord: txt
            )
        }

        #expect(throws:
            HarcBonjourDiscoveryParseError.unexpectedServiceType("_http._tcp")
        ) {
            try HarcBonjourDiscoveryParserV1.parse(
                endpoint: .service(
                    name: "Studio Host",
                    type: "_http._tcp",
                    domain: "local.",
                    interface: nil
                ),
                txtRecord: txt
            )
        }
    }

    @Test("missing or extended TXT records are rejected")
    func rejectsInvalidTXT() throws {
        let endpoint = NWEndpoint.service(
            name: "Studio Host",
            type: HarcBonjourServiceHintsV1.serviceType,
            domain: "local.",
            interface: nil
        )
        #expect(throws: HarcBonjourDiscoveryParseError.missingTXTRecord) {
            try HarcBonjourDiscoveryParserV1.parse(
                endpoint: endpoint,
                txtRecord: nil
            )
        }

        var values = try makeHints().txtRecord
        values["authority"] = "must-not-be-advertised"
        #expect(throws:
            HarcBonjourDiscoveryParseError.invalidTXTRecord(
                .unknownTXTKey("authority")
            )
        ) {
            try HarcBonjourDiscoveryParserV1.parse(
                endpoint: endpoint,
                txtRecord: NWTXTRecord(values)
            )
        }
    }

    @Test("invalid DNS-SD display surfaces are rejected before UI use")
    func validatesServiceSurface() throws {
        let txt = NWTXTRecord(try makeHints().txtRecord)
        #expect(throws: HarcBonjourDiscoveryParseError.invalidServiceName) {
            try HarcBonjourDiscoveryParserV1.parse(
                endpoint: .service(
                    name: " Host",
                    type: HarcBonjourServiceHintsV1.serviceType,
                    domain: "local.",
                    interface: nil
                ),
                txtRecord: txt
            )
        }
    }

    private func makeHints() throws -> HarcBonjourServiceHintsV1 {
        try HarcBonjourServiceHintsV1(
            displayName: "Studio Host",
            protocolMajor: 1,
            protocolMinor: 0,
            capabilityBits: 5,
            uploadPortHint: 8_444
        )
    }
}
#endif
