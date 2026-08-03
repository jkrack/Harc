import Foundation
import HarcDomain
@testable import HarcHost
import HarcIdentity
import HarcProtocol

struct TestHostTransportSetProtocolBoundaryV1: HostTransportSetProtocolBoundary {
    func decodeTransportSet(
        _ request: HostTransportSetDecodeRequest
    ) throws -> HostValidatedTransportSet {
        try project(
            VerifiedHostTransportSetV1.decode(
                request.exactSignedBytes,
                hostAuthorityPublicKey: request.hostAuthorityPublicKey
            )
        )
    }

    func issueTransportSet(
        _ request: HostTransportSetIssueRequest
    ) throws -> HostValidatedTransportSet {
        try project(
            VerifiedHostTransportSetV1.issue(
                libraryID: request.libraryID,
                hostAuthorityID: request.hostAuthorityID,
                setEpoch: request.setEpoch,
                issuedAtUnixMilliseconds: request.issuedAtUnixMilliseconds,
                entries: try request.entries.map {
                    try HostTransportEntryV1(
                        tlsSPKISHA256: $0.tlsSPKISHA256,
                        notBeforeUnixMilliseconds: $0.notBeforeUnixMilliseconds,
                        notAfterUnixMilliseconds: $0.notAfterUnixMilliseconds
                    )
                },
                using: request.hostAuthoritySigner
            )
        )
    }

    func project(
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
