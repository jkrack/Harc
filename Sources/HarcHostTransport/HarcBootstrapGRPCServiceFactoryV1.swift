#if canImport(Network)
import Foundation
import GRPCCore
import HarcHost
import HarcIdentity
import HarcProtocol

/// The production composition root for bootstrap and recording-transfer gRPC.
///
/// One factory owns one transport-source authenticator and one malformed-input
/// gate. Bootstrap services created for a certificate generation therefore
/// share source identity and cooldown state, while the transfer service shares
/// that generation's served TLS binding with session authentication.
package struct HarcBootstrapGRPCServiceFactoryV1: Sendable {
    private let hostInfoApplication: any HarcHostInfoRPCApplication
    private let pairingApplication: any HarcPairingClaimRPCApplication
    private let sessionApplication: any HarcSessionRPCApplication
    private let recordingAdapterForBinding: @Sendable (
        HarcGRPCServedIdentityBinding
    ) -> HarcRecordingTransferGRPCServiceAdapterV1
    private let hostAuthorityPublicKey: P256X963PublicKey
    private let capabilityPolicy: HarcCapabilityPolicyV1
    let sourceBindingProvider: HarcHostRPCSourceBindingProvider
    private let preauthenticationGate: HarcBootstrapPreauthenticationGate

    package init(
        hostInfoService: HarcHostInfoService,
        pairingService: HarcPairingClaimService,
        sessionService: HarcSessionService,
        recordingService: HostRecordingTransferService,
        hostAuthorityPublicKey: P256X963PublicKey,
        capabilityPolicy: HarcCapabilityPolicyV1,
        hostScopedSourceSecret: Data
    ) throws {
        self.hostInfoApplication = hostInfoService
        self.pairingApplication = pairingService
        self.sessionApplication = sessionService
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.capabilityPolicy = capabilityPolicy
        self.recordingAdapterForBinding = { servedIdentityBinding in
            HarcRecordingTransferGRPCServiceAdapterV1(
                service: recordingService,
                sessionService: sessionService,
                capabilityPolicy: capabilityPolicy,
                servedIdentityBinding: servedIdentityBinding
            )
        }
        self.sourceBindingProvider = try HarcHostRPCSourceBindingProvider(
            hostScopedSecret: hostScopedSourceSecret
        )
        self.preauthenticationGate = HarcBootstrapPreauthenticationGate()
    }

    /// Test-only composition seam. Production callers cannot substitute an
    /// arbitrary source provider or split the shared gate across adapters.
    init(
        hostInfoApplication: any HarcHostInfoRPCApplication,
        pairingApplication: any HarcPairingClaimRPCApplication,
        sessionApplication: any HarcSessionRPCApplication,
        recordingApplication: any HarcRecordingTransferRPCApplication,
        recordingSessionAuthenticator:
            any HarcSessionCredentialAuthenticating,
        hostAuthorityPublicKey: P256X963PublicKey,
        capabilityPolicy: HarcCapabilityPolicyV1,
        sourceBindingProvider: HarcHostRPCSourceBindingProvider,
        preauthenticationGate: HarcBootstrapPreauthenticationGate = .init()
    ) {
        self.hostInfoApplication = hostInfoApplication
        self.pairingApplication = pairingApplication
        self.sessionApplication = sessionApplication
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.capabilityPolicy = capabilityPolicy
        self.recordingAdapterForBinding = { servedIdentityBinding in
            HarcRecordingTransferGRPCServiceAdapterV1(
                application: recordingApplication,
                sessionAuthenticator: recordingSessionAuthenticator,
                capabilityPolicy: capabilityPolicy,
                servedIdentityBinding: servedIdentityBinding,
                compatibility: capabilityPolicy.compatibility
            )
        }
        self.sourceBindingProvider = sourceBindingProvider
        self.preauthenticationGate = preauthenticationGate
    }

    func makeServices(
        servedIdentityBinding: HarcGRPCServedIdentityBinding
    ) -> HarcBootstrapGRPCServiceAdaptersV1 {
        HarcBootstrapGRPCServiceAdaptersV1(
            hostInfo: HarcHostInfoGRPCServiceAdapterV1(
                application: hostInfoApplication,
                capabilityPolicy: capabilityPolicy,
                sourceBindingProvider: sourceBindingProvider,
                preauthenticationGate: preauthenticationGate
            ),
            pairing: HarcPairingGRPCServiceAdapterV1(
                application: pairingApplication,
                hostAuthorityPublicKey: hostAuthorityPublicKey,
                servedIdentityBinding: servedIdentityBinding,
                sourceBindingProvider: sourceBindingProvider,
                preauthenticationGate: preauthenticationGate,
                compatibility: capabilityPolicy.compatibility
            ),
            session: HarcSessionGRPCServiceAdapterV1(
                application: sessionApplication,
                capabilityPolicy: capabilityPolicy,
                servedIdentityBinding: servedIdentityBinding,
                sourceBindingProvider: sourceBindingProvider,
                preauthenticationGate: preauthenticationGate,
                compatibility: capabilityPolicy.compatibility
            ),
            recording: recordingAdapterForBinding(servedIdentityBinding)
        )
    }
}

struct HarcBootstrapGRPCServiceAdaptersV1: Sendable {
    let hostInfo: HarcHostInfoGRPCServiceAdapterV1
    let pairing: HarcPairingGRPCServiceAdapterV1
    let session: HarcSessionGRPCServiceAdapterV1
    let recording: HarcRecordingTransferGRPCServiceAdapterV1

    var registrableServices: [any RegistrableRPCService] {
        [hostInfo, pairing, session, recording]
    }
}
#endif
