#if canImport(Network)
@preconcurrency import Foundation
@preconcurrency import Security

/// URLSession server-trust bridge for foreground HTTPS and background upload
/// sessions. It ignores system-root/hostname conclusions and accepts a server
/// trust credential only when the peer supplied Harc's exact one-certificate
/// chain and the shared coordinator has admitted its raw DER and durably
/// committed any transport-set advance.
public final class HarcPinnedURLSessionTrustDelegate: NSObject,
    URLSessionDelegate, @unchecked Sendable {
    public let trustCoordinator: HarcTransportTrustCoordinator

    public init(trustCoordinator: HarcTransportTrustCoordinator) {
        self.trustCoordinator = trustCoordinator
        super.init()
    }

    public func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let certificateChain = SecTrustCopyCertificateChain(serverTrust)
                as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        evaluateServerCertificateChain(
            certificateChain,
            credential: URLCredential(trust: serverTrust),
            completionHandler: completionHandler
        )
    }

    /// Internal chain-extraction seam for adapter tests. Tests pass real
    /// `SecCertificate` values so this exercises the same exact DER export as
    /// the Foundation challenge path without having to synthesize a challenge.
    func evaluateServerCertificateChain(
        _ certificateChain: [SecCertificate],
        credential: URLCredential?,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard certificateChain.count == 1,
              let leaf = certificateChain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        evaluateServerLeaf(
            certificateDER: SecCertificateCopyData(leaf) as Data,
            credential: credential,
            completionHandler: completionHandler
        )
    }

    /// Internal exact-DER seam used by coordinator/callback ordering tests.
    func evaluateServerLeaf(
        certificateDER: Data,
        credential: URLCredential?,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        Task { [trustCoordinator] in
            do {
                try await trustCoordinator.validateServerLeaf(
                    certificateDER: certificateDER
                )
                completionHandler(.useCredential, credential)
            } catch {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
#endif
