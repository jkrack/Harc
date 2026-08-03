import Foundation
import HarcIdentity
import HarcTransfer

// This file deliberately belongs to no SwiftPM target. The focused boundary
// script type-checks it as a consumer outside the Harc package.
func forgeTransportEvidence(
    hostTrust: RecordingHostTrustBinding
) throws {
    _ = try ValidatedTransportSetEvidence(
        hostTrust: hostTrust,
        epoch: 1,
        exactSignedBytes: Data([1])
    )
}

func forgeGrantEvidence(
    hostTrust: RecordingHostTrustBinding,
    claims: DeviceGrantClaims
) throws {
    _ = try ValidatedDeviceGrantEvidence(
        hostTrust: hostTrust,
        claims: claims,
        status: .active,
        exactSignedBytes: Data([2])
    )
}

func forgeAdoptionEvidence(
    hostTrust: RecordingHostTrustBinding,
    transportSet: ValidatedTransportSetEvidence,
    grant: ValidatedDeviceGrantEvidence
) throws {
    _ = try ValidatedClientAdoptionEvidence(
        hostTrust: hostTrust,
        transportSet: transportSet,
        grant: grant,
        adoptedAt: Date()
    )
}

func forgeAuthorityReplacementEvidence(
    replacingHostTrust: RecordingHostTrustBinding,
    replacementAdoption: ValidatedClientAdoptionEvidence
) throws {
    _ = try ValidatedClientAuthorityReplacementEvidence(
        replacingHostTrust: replacingHostTrust,
        replacementAdoption: replacementAdoption
    )
}
