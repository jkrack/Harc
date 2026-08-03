#if canImport(Network)
import Foundation
import NIOEmbedded
import NIOSSL
@preconcurrency import Security
import Testing
@testable import HarcClientTransport

@Suite("Pinned TLS trust adapters")
struct TransportTrustAdapterTests {
    @Test("the concrete NIOSSL verifier admits the raw DER leaf")
    func nioSSLAdapter() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: transport.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let certificateDER = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-client-leaf-\(UUID()).der")
        try certificateDER.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let certificate = try NIOSSLCertificate.fromDERFile(temporaryURL.path)

        let eventLoop = NIOAsyncTestingEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSLVerificationResult.self)
        HarcNIOSSLPeerCertificateVerifier(
            trustCoordinator: coordinator
        ).verify(
            peerCertificateChain: [certificate],
            promise: promise
        )

        let result: NIOSSLVerificationResult
        do {
            result = try await promise.futureResult.get()
        } catch {
            await eventLoop.shutdownGracefully()
            throw error
        }
        await eventLoop.shutdownGracefully()
        guard case .certificateVerified = result else {
            Issue.record("NIOSSL adapter rejected an admitted Harc leaf")
            return
        }
    }

    @Test("the NIOSSL verifier rejects an empty peer chain")
    func nioSSLEmptyChain() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: transport.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey
        )
        let eventLoop = NIOAsyncTestingEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSLVerificationResult.self)

        HarcNIOSSLPeerCertificateVerifier(
            trustCoordinator: coordinator
        ).verify(peerCertificateChain: [], promise: promise)

        let result: NIOSSLVerificationResult
        do {
            result = try await promise.futureResult.get()
        } catch {
            await eventLoop.shutdownGracefully()
            throw error
        }
        await eventLoop.shutdownGracefully()
        guard case .failed = result else {
            Issue.record("NIOSSL adapter accepted an empty peer chain")
            return
        }
    }

    @Test("the NIOSSL verifier rejects an extra peer certificate")
    func nioSSLExtraChain() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: transport.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let certificateDER = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-client-extra-chain-\(UUID()).der")
        try certificateDER.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let certificate = try NIOSSLCertificate.fromDERFile(temporaryURL.path)
        let eventLoop = NIOAsyncTestingEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSLVerificationResult.self)

        HarcNIOSSLPeerCertificateVerifier(
            trustCoordinator: coordinator
        ).verify(
            peerCertificateChain: [certificate, certificate],
            promise: promise
        )

        let result: NIOSSLVerificationResult
        do {
            result = try await promise.futureResult.get()
        } catch {
            await eventLoop.shutdownGracefully()
            throw error
        }
        await eventLoop.shutdownGracefully()
        guard case .failed = result else {
            Issue.record("NIOSSL adapter accepted an extra peer certificate")
            return
        }
    }

    @Test("URLSession does not complete trust until the higher set is durable")
    func urlSessionCommitBeforeCallback() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let initial = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let candidate = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 2
        )
        let persistence = TransportTrustTestPersistence(
            state: try TransportTrustFixtures.persistedState(
                authorityKey: authority,
                verifiedSet: initial
            ),
            blockFirstPersist: true
        )
        let coordinator = HarcTransportTrustCoordinator(
            adoptedPersistence: persistence,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let delegate = HarcPinnedURLSessionTrustDelegate(
            trustCoordinator: coordinator
        )
        let leaf = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: candidate.exactSignedBytes
        )
        let callback = TransportTrustCompletionProbe<Bool>()

        delegate.evaluateServerLeaf(
            certificateDER: leaf,
            credential: nil
        ) { disposition, _ in
            let accepted: Bool
            if case .useCredential = disposition {
                accepted = true
            } else {
                accepted = false
            }
            Task { await callback.record(accepted) }
        }

        for _ in 0..<10_000 {
            if await persistence.isFirstPersistBlocked() { break }
            await Task.yield()
        }
        #expect(await persistence.isFirstPersistBlocked())
        for _ in 0..<100 { await Task.yield() }
        #expect(await callback.snapshot() == nil)

        await persistence.releaseFirstPersist()
        for _ in 0..<10_000 {
            if await callback.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await callback.snapshot() == true)
        #expect(await persistence.currentState()?.highestTransportSetEpoch == 2)
    }

    @Test("URLSession cancels malformed leaf trust with no fallback")
    func urlSessionRejectsMalformedLeaf() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: transport.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey
        )
        let delegate = HarcPinnedURLSessionTrustDelegate(
            trustCoordinator: coordinator
        )
        let callback = TransportTrustCompletionProbe<Bool>()

        delegate.evaluateServerLeaf(
            certificateDER: Data([0x30, 0]),
            credential: nil
        ) { disposition, _ in
            let cancelled: Bool
            if case .cancelAuthenticationChallenge = disposition {
                cancelled = true
            } else {
                cancelled = false
            }
            Task { await callback.record(cancelled) }
        }

        for _ in 0..<10_000 {
            if await callback.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await callback.snapshot() == true)
    }

    @Test("URLSession admits one real SecCertificate and rejects an extra")
    func urlSessionRejectsExtraChain() async throws {
        let authority = try TransportTrustFixtures.authorityKey()
        let tls = try TransportTrustFixtures.tlsKey()
        let transport = try TransportTrustFixtures.transportSet(
            authorityKey: authority,
            tlsKeys: [tls],
            epoch: 1
        )
        let coordinator = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet: transport.exactSignedBytes,
            hostAuthorityPublicKey: authority.publicKey,
            clock: { TransportTrustFixtures.nowMilliseconds }
        )
        let delegate = HarcPinnedURLSessionTrustDelegate(
            trustCoordinator: coordinator
        )
        let leafDER = try TransportTrustFixtures.leafCertificate(
            tlsKey: tls,
            exactTransportSet: transport.exactSignedBytes
        )
        let certificate = try #require(
            SecCertificateCreateWithData(nil, leafDER as CFData)
        )
        #expect(SecCertificateCopyData(certificate) as Data == leafDER)
        let singleCertificateCallback = TransportTrustCompletionProbe<Bool>()

        delegate.evaluateServerCertificateChain(
            [certificate],
            credential: nil
        ) { disposition, _ in
            let accepted: Bool
            if case .useCredential = disposition {
                accepted = true
            } else {
                accepted = false
            }
            Task { await singleCertificateCallback.record(accepted) }
        }

        for _ in 0..<10_000 {
            if await singleCertificateCallback.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await singleCertificateCallback.snapshot() == true)

        let extraCertificateCallback = TransportTrustCompletionProbe<Bool>()

        delegate.evaluateServerCertificateChain(
            [certificate, certificate],
            credential: nil
        ) { disposition, _ in
            let cancelled: Bool
            if case .cancelAuthenticationChallenge = disposition {
                cancelled = true
            } else {
                cancelled = false
            }
            Task { await extraCertificateCallback.record(cancelled) }
        }

        for _ in 0..<10_000 {
            if await extraCertificateCallback.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await extraCertificateCallback.snapshot() == true)
    }
}
#endif
