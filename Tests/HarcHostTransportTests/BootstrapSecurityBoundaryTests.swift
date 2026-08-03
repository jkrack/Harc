import Foundation
import GRPCCore
@testable import HarcHost
@testable import HarcHostTransport
#if canImport(Network)
import Network
#endif
import Testing

@Suite("Host bootstrap security boundaries")
struct BootstrapSecurityBoundaryTests {
    @Test("served identity binding is generation-scoped and terminal")
    func servedIdentityBindingLifecycle() throws {
        let generationID = UUID()
        let otherGenerationID = UUID()
        let digest = Data(repeating: 0x41, count: 32)
        let binding = HarcGRPCServedIdentityBinding(
            generationID: generationID
        )

        #expect(throws: HarcGRPCServedIdentityBindingError.notBound) {
            try binding.requireTLSSPKISHA256(generationID: generationID)
        }
        #expect(throws: HarcGRPCServedIdentityBindingError.wrongGeneration) {
            try binding.bindTestTLSSPKISHA256(
                digest,
                generationID: otherGenerationID
            )
        }

        try binding.bindTestTLSSPKISHA256(
            digest,
            generationID: generationID
        )
        #expect(
            try binding.requireTLSSPKISHA256(generationID: generationID)
                == digest
        )
        #expect(throws: HarcGRPCServedIdentityBindingError.alreadyBound) {
            try binding.bindTestTLSSPKISHA256(
                digest,
                generationID: generationID
            )
        }
        #expect(throws: HarcGRPCServedIdentityBindingError.wrongGeneration) {
            try binding.invalidate(generationID: otherGenerationID)
        }

        try binding.invalidate(generationID: generationID)
        try binding.invalidate(generationID: generationID)
        #expect(throws: HarcGRPCServedIdentityBindingError.invalidated) {
            try binding.requireTLSSPKISHA256(generationID: generationID)
        }
        #expect(throws: HarcGRPCServedIdentityBindingError.invalidated) {
            try binding.bindTestTLSSPKISHA256(
                digest,
                generationID: generationID
            )
        }
    }

    @Test("production source binding removes ports and normalizes network families")
    func normalizedSourceBinding() throws {
        let provider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0x52, count: 32)
        )
        let ipv4 = try provider.sourceBinding(for: peer(
            "ipv4:192.0.2.10:49152"
        ))
        let sameIPv4OtherPort = try provider.sourceBinding(for: peer(
            "ipv4:192.0.2.10:65535"
        ))
        let mappedIPv6 = try provider.sourceBinding(for: peer(
            "ipv6:[::ffff:192.0.2.10]:50000"
        ))
        let compressedIPv6 = try provider.sourceBinding(for: peer(
            "ipv6:[2001:db8::1]:50000"
        ))
        let expandedIPv6 = try provider.sourceBinding(for: peer(
            "ipv6:[2001:0db8:0:0:0:0:0:1]:50001"
        ))
        let linkLocal = try provider.sourceBinding(for: peer(
            "ipv6:[fe80::1]:50000"
        ))
        let scopedLinkLocal = try provider.sourceBinding(for: peer(
            "ipv6:[fe80::1%en0]:50001"
        ))
        let unix = try provider.sourceBinding(for: peer(
            "unix:/tmp/harc-bootstrap.sock"
        ))

        #expect(ipv4 == sameIPv4OtherPort)
        #expect(mappedIPv6 == ipv4)
        #expect(compressedIPv6 == expandedIPv6)
        #expect(linkLocal == scopedLinkLocal)
        #expect(unix != ipv4)
        #expect(ipv4.bindingSHA256.count == 32)
    }

    @Test("source binding rejects ambiguous and unsupported peer descriptions")
    func malformedSourceBinding() throws {
        #expect(throws: HarcHostRPCSourceBindingError.invalidHostScopedSecret) {
            try HarcHostRPCSourceBindingProvider(
                hostScopedSecret: Data(repeating: 0, count: 32)
            )
        }
        let provider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0x62, count: 32)
        )
        let rejected = [
            "<unknown>",
            "remote",
            "ipv4:192.0.2.10:0",
            "ipv4:example.com:50000",
            "ipv6:2001:db8::1:50000",
            "ipv6:[fe80::1%bad zone]:50000",
            "unix:<unknown>",
            "unix:relative.sock",
            "unix:/tmp/../harc.sock",
        ]
        for description in rejected {
            #expect(throws: HarcHostRPCSourceBindingError.unsupportedRemotePeer) {
                try provider.sourceBinding(for: peer(description))
            }
        }
    }

#if canImport(Network)
    @Test("authenticated transport source tokens normalize IPs and reject forgery")
    func authenticatedTransportSourceTokens() throws {
        let provider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0x63, count: 32)
        )
        let ipv4Address = try #require(IPv4Address("192.0.2.10"))
        let mappedAddress = try #require(IPv6Address("::ffff:192.0.2.10"))
        let firstToken = try provider.authenticatedTransportSourceToken(
            for: .hostPort(host: .ipv4(ipv4Address), port: 49_152)
        )
        let otherPortToken = try provider.authenticatedTransportSourceToken(
            for: .hostPort(host: .ipv4(ipv4Address), port: 65_535)
        )
        let mappedToken = try provider.authenticatedTransportSourceToken(
            for: .hostPort(host: .ipv6(mappedAddress), port: 50_000)
        )
        let tokenSource = try provider.sourceBinding(
            authenticatedTransportSourceToken: firstToken
        )
        let peerSource = try provider.sourceBinding(
            for: peer("ipv4:192.0.2.10:49152")
        )

        #expect(firstToken.count == 64)
        #expect(firstToken == otherPortToken)
        #expect(firstToken == mappedToken)
        #expect(tokenSource == peerSource)

        var forgedBinding = firstToken
        forgedBinding[forgedBinding.startIndex] ^= 0x01
        #expect(
            throws: HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        ) {
            try provider.sourceBinding(
                authenticatedTransportSourceToken: forgedBinding
            )
        }

        var forgedTag = firstToken
        forgedTag[forgedTag.index(before: forgedTag.endIndex)] ^= 0x01
        #expect(
            throws: HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        ) {
            try provider.sourceBinding(
                authenticatedTransportSourceToken: forgedTag
            )
        }
        #expect(
            throws: HarcHostRPCSourceBindingError.unsupportedRemotePeer
        ) {
            try provider.authenticatedTransportSourceToken(
                for: .hostPort(host: "example.com", port: 443)
            )
        }
    }

    @Test("admission requires exactly one authenticated internal source token")
    func authenticatedTransportAdmission() async throws {
        let provider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: Data(repeating: 0x64, count: 32)
        )
        let address = try #require(IPv4Address("192.0.2.10"))
        let token = try provider.authenticatedTransportSourceToken(
            for: .hostPort(host: .ipv4(address), port: 49_152)
        )
        let expected = try provider.sourceBinding(
            authenticatedTransportSourceToken: token
        )
        let unknownPeer = HarcHostRPCPeer(
            remotePeer: "<unknown>",
            localPeer: "<unknown>"
        )
        var metadata = Metadata()
        metadata.addBinary(
            Array(token),
            forKey: HarcGRPCTransportSourceBridge.metadataKey
        )

        let admitted = try await HarcHostBootstrapGRPCServiceSupport.admit(
            metadata: metadata,
            peer: unknownPeer,
            sourceBindingProvider: provider,
            gate: HarcBootstrapPreauthenticationGate()
        )
        #expect(admitted == expected)

        metadata.addBinary(
            Array(token),
            forKey: HarcGRPCTransportSourceBridge.metadataKey
        )
        await #expect(
            throws: HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        ) {
            try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: metadata,
                peer: peer("ipv4:192.0.2.10:49152"),
                sourceBindingProvider: provider,
                gate: HarcBootstrapPreauthenticationGate()
            )
        }

        var forgedMetadata = Metadata()
        var forgedToken = token
        forgedToken[forgedToken.startIndex] ^= 0x01
        forgedMetadata.addBinary(
            Array(forgedToken),
            forKey: HarcGRPCTransportSourceBridge.metadataKey
        )
        await #expect(
            throws: HarcHostRPCSourceBindingError
                .invalidAuthenticatedTransportSource
        ) {
            try await HarcHostBootstrapGRPCServiceSupport.admit(
                metadata: forgedMetadata,
                peer: peer("ipv4:192.0.2.10:49152"),
                sourceBindingProvider: provider,
                gate: HarcBootstrapPreauthenticationGate()
            )
        }
    }
#endif

    @Test("malformed admission uses a monotonic one-minute window and ten-minute cooldown")
    func malformedAdmissionCooldown() async throws {
        let time = ManualMonotonicTime()
        let gate = HarcBootstrapPreauthenticationGate(clock: time.clock)
        let source = try HostPreauthenticationSource(
            bindingSHA256: Data(repeating: 0x71, count: 32)
        )

        for _ in 0..<HarcBootstrapPreauthenticationGate
            .maximumMalformedRequestsPerWindow {
            try await gate.admit(source)
            try await gate.recordMalformedRequest(from: source)
        }
        await #expect(
            throws: HarcBootstrapPreauthenticationAdmissionError
                .malformedRequestCooldown
        ) {
            try await gate.admit(source)
        }

        time.advance(seconds: 599)
        await #expect(
            throws: HarcBootstrapPreauthenticationAdmissionError
                .malformedRequestCooldown
        ) {
            try await gate.admit(source)
        }

        time.advance(seconds: 1)
        try await gate.admit(source)
    }

    private func peer(_ remote: String) -> HarcHostRPCPeer {
        HarcHostRPCPeer(
            remotePeer: remote,
            localPeer: "ipv4:192.0.2.20:443"
        )
    }
}

private final class ManualMonotonicTime: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1_000_000_000

    var clock: HarcBootstrapMonotonicClock {
        HarcBootstrapMonotonicClock { [self] in
            lock.withLock { nanoseconds }
        }
    }

    func advance(seconds: UInt64) {
        lock.withLock {
            nanoseconds += seconds * 1_000_000_000
        }
    }
}
