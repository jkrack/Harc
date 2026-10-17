#if os(macOS) && canImport(Network)
import CryptoKit
import Darwin
import Foundation
import GRPCCore
import HarcClientStore
@testable import HarcClientTransport
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
@testable import HarcIdentity
import HarcProtocol
@testable import HarcRemoteTransport
import HarcStore
import HarcTestSupport
import HarcTransfer
@preconcurrency import Network
import Testing

private let pairingLifecycleE2EMarkerURL = URL(
    fileURLWithPath:
        "/tmp/harc-run-pairing-lifecycle-e2e-\(getuid())"
)

// This suite owns a real loopback listener and temporary Keychain certificate.
// Keep it out of the ordinary parallel Swift Testing run: Network.framework's
// listener channel is process-global enough to assert when unrelated transport
// suites tear down concurrently. The dedicated script opts in and filters this
// suite into an isolated process.
@Suite(
    "Pairing lifecycle over pinned gRPC TLS",
    .serialized,
    .processWideSystemResource,
    .enabled(
        if: FileManager.default.fileExists(
            atPath: pairingLifecycleE2EMarkerURL.path
        ),
        "Run scripts/test-pairing-lifecycle.sh"
    )
)
struct PairingLifecycleLoopbackIntegrationTests {
    @Test("pair, authorize, Host-revoke, forget, and same-key re-pair")
    func completeDesktopLifecycle() async throws {
        try await PairingLifecycleLoopbackFixture().run()
    }
}
#endif
