import Foundation
import HarcHost
import HarcProtocol

/// Canonical v1 wire implementation of HarcHost's protocol-neutral
/// transport-set boundary.
package struct HarcHostTransportSetProtocolAdapterV1:
    HostTransportSetProtocolBoundary
{
    package init() {}

    package func decodeTransportSet(
        _ request: HostTransportSetDecodeRequest
    ) throws -> HostValidatedTransportSet {
        try project(
            VerifiedHostTransportSetV1.decode(
                request.exactSignedBytes,
                hostAuthorityPublicKey: request.hostAuthorityPublicKey
            )
        )
    }

    package func issueTransportSet(
        _ request: HostTransportSetIssueRequest
    ) throws -> HostValidatedTransportSet {
        let wireEntries = try request.entries.map {
            try HostTransportEntryV1(
                tlsSPKISHA256: $0.tlsSPKISHA256,
                notBeforeUnixMilliseconds: $0.notBeforeUnixMilliseconds,
                notAfterUnixMilliseconds: $0.notAfterUnixMilliseconds
            )
        }
        return try project(
            VerifiedHostTransportSetV1.issue(
                libraryID: request.libraryID,
                hostAuthorityID: request.hostAuthorityID,
                setEpoch: request.setEpoch,
                issuedAtUnixMilliseconds: request.issuedAtUnixMilliseconds,
                entries: wireEntries,
                using: request.hostAuthoritySigner
            )
        )
    }

    private func project(
        _ verified: VerifiedHostTransportSetV1
    ) throws -> HostValidatedTransportSet {
        try HostValidatedTransportSet(
            exactSignedBytes: verified.exactSignedBytes,
            objectID: verified.signedObject.objectID.rawBytes,
            libraryID: verified.transportSet.libraryID,
            hostAuthorityID: verified.transportSet.hostAuthorityID,
            setEpoch: verified.transportSet.setEpoch,
            issuedAtUnixMilliseconds:
                verified.transportSet.issuedAtUnixMilliseconds,
            entries: try verified.transportSet.entries.map {
                try HostValidatedTransportSetEntry(
                    tlsSPKISHA256: $0.tlsSPKISHA256,
                    notBeforeUnixMilliseconds: $0.notBeforeUnixMilliseconds,
                    notAfterUnixMilliseconds: $0.notAfterUnixMilliseconds
                )
            }
        )
    }
}
