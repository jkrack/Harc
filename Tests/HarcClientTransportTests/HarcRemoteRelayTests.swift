#if canImport(Network)
import Foundation
@testable import HarcRemoteTransport
import Testing

@Suite("Harc Remote relay boundary")
struct HarcRemoteRelayTests {
    @Test("relay URLSession keeps upgraded WebSockets alive")
    func longLivedWebSocketConfiguration() {
        let session = HarcRemoteRelayURLSessionConfiguration.makeEphemeral()
        defer { session.invalidateAndCancel() }

        #expect(
            session.configuration.timeoutIntervalForResource
                == HarcRemoteRelayURLSessionConfiguration.resourceTimeout
        )
        #expect(
            session.configuration.timeoutIntervalForResource >= 24 * 60 * 60
        )
        #expect(session.configuration.timeoutIntervalForRequest == 10)
    }

    @Test("route accepts only HTTPS origins and canonical opaque values")
    func routeValidation() throws {
        let token = String(repeating: "A", count: 43)
        let route = try HarcRemoteRelayRouteV1(
            serviceOrigin: #require(URL(string: "https://relay.harc.example")),
            hostRouteID: token,
            deviceRouteID: String(repeating: "b", count: 42) + "A",
            capability: String(repeating: "7", count: 42) + "A"
        )

        #expect(route.serviceOrigin.absoluteString == "https://relay.harc.example")
        #expect(HarcRemoteRelayRouteV1.isOpaqueToken(token))
        #expect(!HarcRemoteRelayRouteV1.isOpaqueToken(token + "A"))
        #expect(!HarcRemoteRelayRouteV1.isOpaqueToken(
            String(repeating: "B", count: 43)
        ))
        #expect(!HarcRemoteRelayRouteV1.isOpaqueToken(String(repeating: "+", count: 43)))

        #expect(throws: HarcRemoteRelayError.invalidServiceOrigin) {
            try HarcRemoteRelayRouteV1(
                serviceOrigin: #require(URL(string: "http://relay.harc.example")),
                hostRouteID: token,
                deviceRouteID: token,
                capability: token
            )
        }
        #expect(throws: HarcRemoteRelayError.invalidServiceOrigin) {
            try HarcRemoteRelayRouteV1(
                serviceOrigin: #require(URL(string: "https://relay.harc.example/path")),
                hostRouteID: token,
                deviceRouteID: token,
                capability: token
            )
        }
    }

    @Test("decoded persisted routes revalidate secrets and origins")
    func persistedRouteValidation() throws {
        let invalid = Data(#"{"serviceOrigin":"https:\/\/relay.harc.example","hostRouteID":"short","deviceRouteID":"short","capability":"short"}"#.utf8)
        #expect(throws: HarcRemoteRelayError.invalidOpaqueValue(field: "hostRouteID")) {
            try JSONDecoder().decode(HarcRemoteRelayRouteV1.self, from: invalid)
        }
    }

    @Test("Host relay identity is secure, canonical, and decode-validating")
    func hostConfigurationValidation() throws {
        let origin = try #require(URL(string: "https://relay.harc.example"))
        let configuration = try HarcRemoteRelayHostConfigurationV1.generate(
            serviceOrigin: origin,
            localControlPort: 49_483
        )
        #expect(HarcRemoteRelayRouteV1.isOpaqueToken(configuration.hostRouteID))
        #expect(HarcRemoteRelayRouteV1.isOpaqueToken(configuration.hostCapability))
        #expect(
            HarcRemoteRelayRouteV1.isOpaqueToken(
                try HarcRemoteRelaySecrets.hashOpaqueToken(
                    configuration.hostCapability
                )
            )
        )

        let encoded = try JSONEncoder().encode(configuration)
        #expect(
            try JSONDecoder().decode(
                HarcRemoteRelayHostConfigurationV1.self,
                from: encoded
            ) == configuration
        )
        #expect(throws: HarcRemoteRelayError.invalidLocalControlPort) {
            try HarcRemoteRelayHostConfigurationV1(
                serviceOrigin: origin,
                hostRouteID: configuration.hostRouteID,
                hostCapability: configuration.hostCapability,
                localControlPort: 0
            )
        }
    }

    @Test("session offer rejects unknown fields, booleans, and excessive lifetime")
    func sessionOfferValidation() throws {
        let sessionID = String(repeating: "S", count: 42) + "A"
        let capability = String(repeating: "c", count: 42) + "A"
        let now: UInt64 = 1_000_000
        let valid = Data(
            "{\"capability\":\"\(capability)\",\"expiresAt\":\(now + 60_000),\"sessionID\":\"\(sessionID)\"}".utf8
        )
        let offer = try HarcRemoteRelaySessionOfferV1.decode(
            valid,
            nowMilliseconds: now
        )
        #expect(offer.sessionID == sessionID)
        #expect(offer.capability == capability)

        let unknown = Data(
            "{\"capability\":\"\(capability)\",\"expiresAt\":\(now + 60_000),\"sessionID\":\"\(sessionID)\",\"deviceName\":\"must-not-cross\"}".utf8
        )
        #expect(throws: HarcRemoteRelayError.invalidSessionOffer) {
            try HarcRemoteRelaySessionOfferV1.decode(
                unknown,
                nowMilliseconds: now
            )
        }

        let boolean = Data(
            "{\"capability\":\"\(capability)\",\"expiresAt\":true,\"sessionID\":\"\(sessionID)\"}".utf8
        )
        #expect(throws: HarcRemoteRelayError.invalidSessionOffer) {
            try HarcRemoteRelaySessionOfferV1.decode(
                boolean,
                nowMilliseconds: now
            )
        }

        let excessive = Data(
            "{\"capability\":\"\(capability)\",\"expiresAt\":\(now + HarcRemoteRelayLimits.sessionLifetimeMilliseconds + 1),\"sessionID\":\"\(sessionID)\"}".utf8
        )
        #expect(throws: HarcRemoteRelayError.invalidSessionOffer) {
            try HarcRemoteRelaySessionOfferV1.decode(
                excessive,
                nowMilliseconds: now
            )
        }
    }

    @Test("Host session offers require the exact control schema")
    func hostSessionOfferValidation() throws {
        let sessionID = String(repeating: "S", count: 42) + "A"
        let capability = String(repeating: "c", count: 42) + "A"
        let now: UInt64 = 1_000_000
        let valid = Data(
            "{\"capability\":\"\(capability)\",\"expiresAt\":\(now + 60_000),\"sessionID\":\"\(sessionID)\",\"type\":\"session\"}".utf8
        )
        let offer = try HarcRemoteRelayHostSessionOfferV1.decode(
            valid,
            nowMilliseconds: now
        )
        #expect(offer.sessionID == sessionID)

        let leakedIdentity = Data(
            "{\"capability\":\"\(capability)\",\"deviceName\":\"must-not-cross\",\"expiresAt\":\(now + 60_000),\"sessionID\":\"\(sessionID)\",\"type\":\"session\"}".utf8
        )
        #expect(throws: HarcRemoteRelayError.invalidSessionOffer) {
            try HarcRemoteRelayHostSessionOfferV1.decode(
                leakedIdentity,
                nowMilliseconds: now
            )
        }
    }

    @Test("feature remains disabled without explicit opt-in")
    func featureGate() {
        #expect(!HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: [:],
            userDefaults: nil
        ))
        #expect(HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: ["HARC_ENABLE_REMOTE_RELAY": "1"],
            userDefaults: nil
        ))
        #expect(!HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: ["HARC_ENABLE_REMOTE_RELAY": "true"],
            userDefaults: nil
        ))

        let suiteName = "HarcRemoteRelayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: [:],
            userDefaults: defaults
        ))
        defaults.set(true, forKey: "harc.remoteRelayEnabled")
        #expect(HarcRemoteRelayFeaturePolicy.isEnabled(
            environment: [:],
            userDefaults: defaults
        ))
    }
}
#endif
