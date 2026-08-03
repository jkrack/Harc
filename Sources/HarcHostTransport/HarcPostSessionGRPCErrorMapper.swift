import Foundation
import GRPCCore
import HarcHost
import HarcProtocol
import HarcTransfer

/// Fail-closed translation for authenticated recording-transfer RPCs.
///
/// Public messages intentionally describe only the error class. They never
/// include device identifiers, upload identifiers, generation numbers, quota
/// values, filesystem paths, database details, or whether an object exists.
enum HarcPostSessionGRPCErrorMapper {
    static func map(_ error: any Error) -> RPCError {
        if let rpcError = error as? RPCError {
            return rpcError
        }
        if error is CancellationError {
            return Kind.cancelled.rpcError
        }
        if error is HarcSessionAuthorizationV1Error {
            return Kind.unauthenticated.rpcError
        }
        if error is HarcGRPCServedIdentityBindingError {
            return Kind.unavailable.rpcError
        }
        if let error = error as? HarcHostRPCSourceBindingError {
            return map(error).rpcError
        }
        if let error = error as? HarcBootstrapPreauthenticationAdmissionError {
            return map(error).rpcError
        }
        if let error = error as? HarcProtobufConversionError {
            return map(error).rpcError
        }
        if let error = error as? HarcProtocolCodecError {
            return map(error).rpcError
        }
        if let error = error as? TransferValidationError {
            return map(error).rpcError
        }
        if let error = error as? HarcHostError {
            return map(error).rpcError
        }
        return Kind.internalFailure.rpcError
    }

    private enum Kind {
        case cancelled
        case unauthenticated
        case permissionDenied
        case resourceExhausted
        case invalidArgument
        case failedPrecondition
        case conflict
        case unavailable
        case internalFailure

        var rpcError: RPCError {
            switch self {
            case .cancelled:
                RPCError(
                    code: .cancelled,
                    message: "The operation was cancelled."
                )
            case .unauthenticated:
                RPCError(
                    code: .unauthenticated,
                    message: "Authentication was rejected."
                )
            case .permissionDenied:
                RPCError(
                    code: .permissionDenied,
                    message: "The operation is not permitted."
                )
            case .resourceExhausted:
                RPCError(
                    code: .resourceExhausted,
                    message: "The host cannot accept more transfer work."
                )
            case .invalidArgument:
                RPCError(
                    code: .invalidArgument,
                    message: "The request is malformed."
                )
            case .failedPrecondition:
                RPCError(
                    code: .failedPrecondition,
                    message: "The operation requires different durable state."
                )
            case .conflict:
                RPCError(
                    code: .aborted,
                    message: "The operation conflicted with durable state."
                )
            case .unavailable:
                RPCError(
                    code: .unavailable,
                    message: "The host is temporarily unavailable."
                )
            case .internalFailure:
                RPCError(
                    code: .internalError,
                    message: "The host could not complete the request."
                )
            }
        }
    }

    private static func map(_ error: HarcHostRPCSourceBindingError) -> Kind {
        switch error {
        case .invalidHostScopedSecret:
            .internalFailure
        case .invalidAuthenticatedTransportSource, .unsupportedRemotePeer:
            .invalidArgument
        }
    }

    private static func map(
        _ error: HarcBootstrapPreauthenticationAdmissionError
    ) -> Kind {
        switch error {
        case .malformedRequestCooldown, .sourceCapacityExhausted:
            .resourceExhausted
        case .monotonicClockRegression:
            .unavailable
        }
    }

    private static func map(_ error: HarcProtobufConversionError) -> Kind {
        switch error {
        case .unsupportedRequiredFeature, .unknownCriticalField:
            .failedPrecondition
        case .inputTooLarge, .malformedProtobuf, .missingField,
             .invalidLength, .invalidValue, .integerOutOfRange,
             .unsupportedEnum, .nonCanonicalOrder, .duplicateValue,
             .exactPayloadHashMismatch, .lossyConversion, .inconsistentField:
            .invalidArgument
        }
    }

    private static func map(_ error: HarcProtocolCodecError) -> Kind {
        switch error {
        case .unsupportedProtocolMajor, .unsupportedProtocolMinor,
             .expired, .currentGrantRequired, .staleGrant,
             .commandExpired, .commandLifetimeExceeded:
            .failedPrecondition
        case .invalidSASDictionary:
            .internalFailure
        case .inputTooLarge, .truncated, .trailingBytes, .invalidMagic,
             .lengthOutOfRange, .lengthMismatch, .invalidTimeRange,
             .nonCanonicalOrder, .duplicateValue, .invalidText,
             .invalidEndpoint, .invalidBase64URL, .invalidPairingURI,
             .invalidKeyBinding, .invalidDigest, .invalidSignature,
             .payloadHashMismatch, .unregisteredSignedObject,
             .wrongSignerClass, .headerPayloadMismatch,
             .missingPayloadBinding, .numericOverflow:
            .invalidArgument
        }
    }

    private static func map(_ error: TransferValidationError) -> Kind {
        switch error {
        case .chunkConflict:
            .conflict
        case .profileMismatch, .declarationBlocked, .declarationClosed,
             .incompleteChunkCoverage, .staleUploadGeneration,
             .uploadExpired, .uploadNotExpired, .uploadTerminal,
             .receiptEvidenceRequired, .evidenceBindingMismatch,
             .reconciliationMismatch:
            .failedPrecondition
        case .invalidOutboxTransition:
            .internalFailure
        case .invalidDigestLength, .invalidLength, .exceedsLimit,
             .invalidDate, .invalidOrdering, .duplicateIdentifier,
             .numericOverflow, .invalidCanonicalFormat,
             .originDeviceMismatch, .discontinuityRecordingMismatch,
             .frameRangeOutsideCapture, .inconsistentCanonicalByteCount,
             .incompatibleCodecAndContainer, .invalidCodecParameters,
             .rawPCMRestrictedToFixtures, .invalidCapabilityIdentifier,
             .nonContiguousDeclaration, .invalidUploadAttempt,
             .emptyExactObject, .wrongExactObjectKind:
            .invalidArgument
        }
    }

    private static func map(_ error: HarcHostError) -> Kind {
        switch error {
        case .invalidAuthenticationInput, .pairingClaimRejected,
             .pairingProofRejected, .sessionAdmissionRejected,
             .sessionProofRejected, .sessionCredentialRejected,
             .emergencyTrustRepairRequired, .unknownDevice, .deviceRevoked,
             .grantExpired, .grantMismatch:
            .unauthenticated

        // `uploadNotFound` deliberately shares the ownership/scope response so
        // callers cannot use status codes or messages as an existence oracle.
        case .localOSAuthenticationRequired, .missingScope,
             .objectOwnershipMismatch, .uploadNotFound:
            .permissionDenied

        case .publicHostInfoRateLimited, .operationCapacityExhausted,
             .activeStagingStreamLimitExceeded, .quotaExceeded,
             .insufficientFreeSpace:
            .resourceExhausted

        case .replayConflict, .operationResultConflict,
             .preparedEffectConflict, .canonicalPublicationAlreadyInProgress,
             .canonicalDestinationExists, .provenanceSidecarConflict:
            .conflict

        case .invalidPairingTransition, .pairingClaimNotAwaitingApproval,
             .pairingGrantMismatch, .securityMutationAlreadyPending,
             .securityRegistryTransitionInProgress,
             .hostAuthorityMutationConflict,
             .transportRetirementFloorNotReached, .commandExpired,
             .commandIssuedInFuture, .uploadConflict,
             .staleUploadGeneration, .manifestEvidenceRequired,
             .incompleteCanonicalUpload, .operationPreparedRequiresRecovery,
             .publicationRecoveryRequired, .publicationCheckpointConflict,
             .qualifiedDecoderUnavailable, .fixtureDecoderForbidden:
            .failedPrecondition

        case .invalidDigestLength, .invalidMessageType,
             .invalidOperationID, .invalidOperationSigner,
             .invalidHostInfoInput, .securityMutationInvalid,
             .operationPayloadTooLarge, .encodedLengthMismatch,
             .encodedHashMismatch, .bodyFragmentTooLarge, .incompleteBody,
             .invalidCanonicalFrameCount, .decodedLengthMismatch,
             .canonicalHashMismatch, .classicRIFFSizeExceeded:
            .invalidArgument

        case .databaseOpenFailed, .migrationFailed, .databaseFailure,
             .metadataMismatch, .securityRegistryRollback,
             .securityRegistryPendingMismatch,
             .deferredServingBootstrapRequired,
             .deferredServingPreflightMismatch,
             .transportSetTransitionInProgress, .transportSetNotInitialized,
             .transportSetPendingMismatch, .transportSetRollback,
             .invalidTransportSet, .tlsLeafMismatch, .tlsLeafNotReady,
             .transportRotationStateMismatch, .volumeCapacityUnavailable,
             .unsafeStagingRoot, .unsafeStagingPath, .stagingIO,
             .unsafePublicationRoot, .unsafePublicationPath, .publicationIO,
             .processingSchedulerUnavailable:
            .unavailable

        case .canonicalCommitUnavailableUntilPR5,
             .canonicalArtifactIdentityMismatch, .invalidCanonicalWAV:
            .internalFailure
        }
    }
}
