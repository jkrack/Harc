import CryptoKit
import Foundation
import HarcDomain
import HarcIdentity

/// Protocol-neutral projection of one authenticated transport-set entry.
///
/// The wire adapter is responsible for signature and registered-envelope
/// verification. HarcHost independently retains the structural invariants it
/// relies on for publication, certificate validity, and rotation decisions.
package struct HostValidatedTransportSetEntry: Equatable, Hashable, Sendable {
    package static let maximumLifetimeMilliseconds: UInt64 =
        90 * 24 * 60 * 60 * 1_000
    package static let clockSkewMilliseconds: UInt64 = 5 * 60 * 1_000

    package let tlsSPKISHA256: Data
    package let notBeforeUnixMilliseconds: UInt64
    package let notAfterUnixMilliseconds: UInt64

    package init(
        tlsSPKISHA256: Data,
        notBeforeUnixMilliseconds: UInt64,
        notAfterUnixMilliseconds: UInt64
    ) throws {
        guard tlsSPKISHA256.count == SHA256.byteCount else {
            throw HarcHostError.invalidTransportSet("TLS SPKI digest")
        }
        guard notAfterUnixMilliseconds > notBeforeUnixMilliseconds,
              notAfterUnixMilliseconds - notBeforeUnixMilliseconds
                <= Self.maximumLifetimeMilliseconds else {
            throw HarcHostError.invalidTransportSet("transport entry validity")
        }
        self.tlsSPKISHA256 = tlsSPKISHA256
        self.notBeforeUnixMilliseconds = notBeforeUnixMilliseconds
        self.notAfterUnixMilliseconds = notAfterUnixMilliseconds
    }

    package func isValid(
        atUnixMilliseconds time: UInt64,
        clockSkewMilliseconds: UInt64 = Self.clockSkewMilliseconds
    ) -> Bool {
        let earliest = notBeforeUnixMilliseconds > clockSkewMilliseconds
            ? notBeforeUnixMilliseconds - clockSkewMilliseconds
            : 0
        let latest = notAfterUnixMilliseconds.addingReportingOverflow(
            clockSkewMilliseconds
        )
        return time >= earliest
            && time <= (latest.overflow ? UInt64.max : latest.partialValue)
    }
}

/// Exact authenticated transport-set evidence admitted by the injected wire
/// boundary. This deliberately contains no HarcProtocol type: the lifecycle
/// consumes only the verified tuple, epoch, time, entries, exact bytes, and
/// object identifier it needs to preserve durable publication semantics.
package struct HostValidatedTransportSet: Equatable, Sendable {
    package static let maximumExactSignedBytes = 4 * 1_024
    package static let maximumEntries = 2

    package let exactSignedBytes: Data
    package let objectID: Data
    package let libraryID: LibraryID
    package let hostAuthorityID: HostAuthorityID
    package let setEpoch: UInt64
    package let issuedAtUnixMilliseconds: UInt64
    package let entries: [HostValidatedTransportSetEntry]

    package init(
        exactSignedBytes: Data,
        objectID: Data,
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        setEpoch: UInt64,
        issuedAtUnixMilliseconds: UInt64,
        entries: [HostValidatedTransportSetEntry]
    ) throws {
        guard (1 ... Self.maximumExactSignedBytes).contains(exactSignedBytes.count) else {
            throw HarcHostError.invalidTransportSet("exact signed byte length")
        }
        guard objectID.count == SHA256.byteCount else {
            throw HarcHostError.invalidTransportSet("transport-set object ID")
        }
        guard setEpoch > 0,
              (1 ... Self.maximumEntries).contains(entries.count) else {
            throw HarcHostError.invalidTransportSet("transport-set epoch or entry count")
        }
        for (prior, current) in zip(entries, entries.dropFirst()) {
            guard prior.tlsSPKISHA256.lexicographicallyPrecedes(
                current.tlsSPKISHA256
            ) else {
                throw HarcHostError.invalidTransportSet(
                    "canonical transport entry order"
                )
            }
        }
        self.exactSignedBytes = exactSignedBytes
        self.objectID = objectID
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.setEpoch = setEpoch
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.entries = entries
    }
}

/// HarcHost-owned input wrapper that keeps the transport adapter's public
/// witness surface independent of HarcDomain and HarcIdentity module names.
package struct HostTransportSetDecodeRequest: Sendable {
    package let exactSignedBytes: Data
    package let hostAuthorityPublicKey: P256X963PublicKey

    package init(
        exactSignedBytes: Data,
        hostAuthorityPublicKey: P256X963PublicKey
    ) {
        self.exactSignedBytes = exactSignedBytes
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
    }
}

/// HarcHost-owned issuance input. The concrete transport adapter receives the
/// already-validated lifecycle values without taking direct dependencies on
/// their defining lower-level modules.
package struct HostTransportSetIssueRequest: Sendable {
    package let libraryID: LibraryID
    package let hostAuthorityID: HostAuthorityID
    package let setEpoch: UInt64
    package let issuedAtUnixMilliseconds: UInt64
    package let entries: [HostValidatedTransportSetEntry]
    package let hostAuthoritySigner: any P256DigestSigner

    package init(
        libraryID: LibraryID,
        hostAuthorityID: HostAuthorityID,
        setEpoch: UInt64,
        issuedAtUnixMilliseconds: UInt64,
        entries: [HostValidatedTransportSetEntry],
        hostAuthoritySigner: any P256DigestSigner
    ) {
        self.libraryID = libraryID
        self.hostAuthorityID = hostAuthorityID
        self.setEpoch = setEpoch
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.entries = entries
        self.hostAuthoritySigner = hostAuthoritySigner
    }
}

/// Authentication/codec seam supplied by HarcHostTransport. Implementations
/// must return a projection only after authenticating the exact registered
/// object and validating every envelope/payload mirror.
package protocol HostTransportSetProtocolBoundary: Sendable {
    func decodeTransportSet(
        _ request: HostTransportSetDecodeRequest
    ) throws -> HostValidatedTransportSet

    /// Issues through the canonical producer and readmits the result through
    /// the same authenticated decode path used for persisted/client bytes.
    func issueTransportSet(
        _ request: HostTransportSetIssueRequest
    ) throws -> HostValidatedTransportSet
}
