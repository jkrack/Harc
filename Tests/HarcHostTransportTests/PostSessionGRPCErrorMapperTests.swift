import Foundation
import GRPCCore
import HarcDomain
import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Testing

@Suite("Post-session gRPC error mapper")
struct PostSessionGRPCErrorMapperTests {
    @Test("authentication currentness failures are indistinguishable")
    func authenticationMappings() {
        assertMapped(
            [
                HarcSessionAuthorizationV1Error.invalidAuthorization,
                HarcHostError.invalidAuthenticationInput("credential"),
                HarcHostError.pairingClaimRejected,
                HarcHostError.pairingProofRejected,
                HarcHostError.sessionAdmissionRejected,
                HarcHostError.sessionProofRejected,
                HarcHostError.sessionCredentialRejected,
                HarcHostError.emergencyTrustRepairRequired,
                HarcHostError.unknownDevice,
                HarcHostError.deviceRevoked,
                HarcHostError.grantExpired,
                HarcHostError.grantMismatch,
            ],
            code: .unauthenticated,
            message: "Authentication was rejected."
        )
    }

    @Test("scope ownership and absence do not reveal object existence")
    func permissionMappings() {
        assertMapped(
            [
                HarcHostError.localOSAuthenticationRequired,
                HarcHostError.missingScope(.recordingUploadOwn),
                HarcHostError.objectOwnershipMismatch,
                HarcHostError.uploadNotFound,
            ],
            code: .permissionDenied,
            message: "The operation is not permitted."
        )
    }

    @Test("capacity stream quota and free-space failures exhaust resources")
    func resourceMappings() {
        assertMapped(
            [
                HarcHostError.publicHostInfoRateLimited,
                HarcHostError.operationCapacityExhausted,
                HarcHostError.activeStagingStreamLimitExceeded(limit: 2),
                HarcHostError.quotaExceeded(
                    scope: "device-secret",
                    limit: 10,
                    requestedTotal: 11
                ),
                HarcHostError.insufficientFreeSpace(
                    requiredBytes: 10,
                    availableBytes: 9
                ),
                HarcBootstrapPreauthenticationAdmissionError
                    .malformedRequestCooldown,
                HarcBootstrapPreauthenticationAdmissionError
                    .sourceCapacityExhausted,
            ],
            code: .resourceExhausted,
            message: "The host cannot accept more transfer work."
        )
    }

    @Test("durable conflicts abort without leaking identifiers")
    func conflictMappings() throws {
        assertMapped(
            [
                HarcHostError.replayConflict,
                HarcHostError.operationResultConflict,
                HarcHostError.preparedEffectConflict,
                HarcHostError.canonicalPublicationAlreadyInProgress(.random()),
                HarcHostError.canonicalDestinationExists,
                HarcHostError.provenanceSidecarConflict,
                TransferValidationError.chunkConflict(try chunkConflict()),
            ],
            code: .aborted,
            message: "The operation conflicted with durable state."
        )
    }

    @Test("stale terminal recovery and semantic requirements fail precondition")
    func preconditionMappings() {
        assertMapped(
            hostPreconditionErrors()
                + transferPreconditionErrors()
                + protocolPreconditionErrors()
                + protobufPreconditionErrors(),
            code: .failedPrecondition,
            message: "The operation requires different durable state."
        )
    }

    @Test("malformed host transfer protocol and protobuf input is invalid")
    func invalidArgumentMappings() {
        assertMapped(
            hostInvalidArgumentErrors()
                + transferInvalidArgumentErrors()
                + protocolInvalidArgumentErrors()
                + protobufInvalidArgumentErrors()
                + [
                    HarcHostRPCSourceBindingError
                        .invalidAuthenticatedTransportSource,
                    HarcHostRPCSourceBindingError.unsupportedRemotePeer,
                ],
            code: .invalidArgument,
            message: "The request is malformed."
        )
    }

    @Test("durable infrastructure and served-identity failures are unavailable")
    func unavailableMappings() {
        assertMapped(
            hostUnavailableErrors()
                + [
                    HarcGRPCServedIdentityBindingError.wrongGeneration,
                    HarcGRPCServedIdentityBindingError.notBound,
                    HarcGRPCServedIdentityBindingError.alreadyBound,
                    HarcGRPCServedIdentityBindingError.invalidated,
                    HarcGRPCServedIdentityBindingError
                        .invalidTLSSPKISHA256,
                    HarcBootstrapPreauthenticationAdmissionError
                        .monotonicClockRegression,
                ],
            code: .unavailable,
            message: "The host is temporarily unavailable."
        )
    }

    @Test("host invariants unknown failures and local secret errors are internal")
    func internalMappings() {
        assertMapped(
            [
                HarcHostError.canonicalArtifactIdentityMismatch,
                HarcHostError.invalidCanonicalWAV,
                TransferValidationError.invalidOutboxTransition(
                    from: "private-before",
                    to: "private-after"
                ),
                HarcProtocolCodecError.invalidSASDictionary,
                HarcHostRPCSourceBindingError.invalidHostScopedSecret,
                UnknownTestError.failure("private-detail"),
            ],
            code: .internalError,
            message: "The host could not complete the request."
        )
    }

    @Test("cancellation is generic and explicit RPC errors pass through")
    func transportErrors() {
        let cancelled = HarcPostSessionGRPCErrorMapper.map(
            CancellationError()
        )
        #expect(cancelled.code == .cancelled)
        #expect(cancelled.message == "The operation was cancelled.")

        let explicit = RPCError(
            code: .deadlineExceeded,
            message: "explicit-adapter-status"
        )
        let mapped = HarcPostSessionGRPCErrorMapper.map(explicit)
        #expect(mapped.code == explicit.code)
        #expect(mapped.message == explicit.message)
    }

    private func hostPreconditionErrors() -> [any Error] {
        [
            HarcHostError.invalidPairingTransition,
            HarcHostError.pairingClaimNotAwaitingApproval,
            HarcHostError.pairingGrantMismatch,
            HarcHostError.securityMutationAlreadyPending,
            HarcHostError.securityRegistryTransitionInProgress,
            HarcHostError.hostAuthorityMutationConflict,
            HarcHostError.transportRetirementFloorNotReached(
                requiredUnixMilliseconds: 42
            ),
            HarcHostError.commandExpired,
            HarcHostError.commandIssuedInFuture,
            HarcHostError.uploadConflict("private-upload-detail"),
            HarcHostError.staleUploadGeneration(expected: 4, actual: 3),
            HarcHostError.manifestEvidenceRequired,
            HarcHostError.incompleteCanonicalUpload,
            HarcHostError.operationPreparedRequiresRecovery,
            HarcHostError.publicationRecoveryRequired("private-path"),
            HarcHostError.publicationCheckpointConflict(
                expected: ["private-state"],
                actual: "private-actual"
            ),
            HarcHostError.qualifiedDecoderUnavailable(
                codec: "private-codec",
                container: "private-container"
            ),
            HarcHostError.fixtureDecoderForbidden,
        ]
    }

    private func hostInvalidArgumentErrors() -> [any Error] {
        [
            HarcHostError.invalidDigestLength(
                field: "private-field",
                expected: 32,
                actual: 31
            ),
            HarcHostError.invalidMessageType("private-type"),
            HarcHostError.invalidOperationID,
            HarcHostError.invalidOperationSigner,
            HarcHostError.invalidHostInfoInput("private-field"),
            HarcHostError.securityMutationInvalid("private-detail"),
            HarcHostError.operationPayloadTooLarge,
            HarcHostError.encodedLengthMismatch(expected: 4, actual: 3),
            HarcHostError.encodedHashMismatch,
            HarcHostError.bodyFragmentTooLarge(limit: 4, actual: 5),
            HarcHostError.incompleteBody,
            HarcHostError.invalidCanonicalFrameCount(0),
            HarcHostError.decodedLengthMismatch(expected: 4, actual: 3),
            HarcHostError.canonicalHashMismatch,
            HarcHostError.classicRIFFSizeExceeded(
                maximumPCMBytes: 4,
                requestedPCMBytes: 5
            ),
        ]
    }

    private func hostUnavailableErrors() -> [any Error] {
        [
            HarcHostError.databaseOpenFailed("private-path"),
            HarcHostError.migrationFailed("private-schema"),
            HarcHostError.databaseFailure("private-sql"),
            HarcHostError.metadataMismatch,
            HarcHostError.securityRegistryRollback(
                databaseRevision: 1,
                highWaterRevision: 2
            ),
            HarcHostError.securityRegistryPendingMismatch,
            HarcHostError.deferredServingBootstrapRequired,
            HarcHostError.deferredServingPreflightMismatch,
            HarcHostError.transportSetTransitionInProgress,
            HarcHostError.transportSetNotInitialized,
            HarcHostError.transportSetPendingMismatch,
            HarcHostError.transportSetRollback(
                databaseEpoch: 1,
                highWaterEpoch: 2
            ),
            HarcHostError.invalidTransportSet("private-transport"),
            HarcHostError.tlsLeafMismatch("private-certificate"),
            HarcHostError.tlsLeafNotReady,
            HarcHostError.transportRotationStateMismatch,
            HarcHostError.volumeCapacityUnavailable,
            HarcHostError.unsafeStagingRoot,
            HarcHostError.unsafeStagingPath,
            HarcHostError.stagingIO("private-path"),
            HarcHostError.unsafePublicationRoot,
            HarcHostError.unsafePublicationPath,
            HarcHostError.publicationIO("private-path"),
            HarcHostError.processingSchedulerUnavailable,
        ]
    }

    private func transferPreconditionErrors() -> [any Error] {
        [
            TransferValidationError.profileMismatch(field: "private-field"),
            TransferValidationError.declarationBlocked,
            TransferValidationError.declarationClosed,
            TransferValidationError.incompleteChunkCoverage(
                expectedFrames: 4,
                actualFrames: 3
            ),
            TransferValidationError.staleUploadGeneration(
                expected: 4,
                actual: 3
            ),
            TransferValidationError.uploadExpired,
            TransferValidationError.uploadNotExpired,
            TransferValidationError.uploadTerminal,
            TransferValidationError.receiptEvidenceRequired,
            TransferValidationError.evidenceBindingMismatch(
                field: "private-binding"
            ),
            TransferValidationError.reconciliationMismatch(
                reason: "private-state"
            ),
        ]
    }

    private func transferInvalidArgumentErrors() -> [any Error] {
        [
            TransferValidationError.invalidDigestLength(
                field: "private-field",
                expected: 32,
                actual: 31
            ),
            TransferValidationError.invalidLength(
                field: "private-field",
                value: 0
            ),
            TransferValidationError.exceedsLimit(
                field: "private-field",
                limit: 4,
                actual: 5
            ),
            TransferValidationError.invalidDate(field: "private-field"),
            TransferValidationError.invalidOrdering(field: "private-field"),
            TransferValidationError.duplicateIdentifier(
                field: "private-field"
            ),
            TransferValidationError.numericOverflow(field: "private-field"),
            TransferValidationError.invalidCanonicalFormat,
            TransferValidationError.originDeviceMismatch,
            TransferValidationError.discontinuityRecordingMismatch,
            TransferValidationError.frameRangeOutsideCapture,
            TransferValidationError.inconsistentCanonicalByteCount(
                expected: 4,
                actual: 3
            ),
            TransferValidationError.incompatibleCodecAndContainer,
            TransferValidationError.invalidCodecParameters(
                reason: "private-codec"
            ),
            TransferValidationError.rawPCMRestrictedToFixtures,
            TransferValidationError.invalidCapabilityIdentifier(
                "private-capability"
            ),
            TransferValidationError.nonContiguousDeclaration(
                expectedIndex: 2,
                expectedStartFrame: 4
            ),
            TransferValidationError.invalidUploadAttempt(
                reason: "private-state"
            ),
            TransferValidationError.emptyExactObject,
            TransferValidationError.wrongExactObjectKind(
                expected: .recordingManifestV1,
                actual: .recordingReceiptV1
            ),
        ]
    }

    private func protocolPreconditionErrors() -> [any Error] {
        [
            HarcProtocolCodecError.unsupportedProtocolMajor(2),
            HarcProtocolCodecError.unsupportedProtocolMinor(2),
            HarcProtocolCodecError.expired(field: "private-field"),
            HarcProtocolCodecError.currentGrantRequired,
            HarcProtocolCodecError.staleGrant,
            HarcProtocolCodecError.commandExpired,
            HarcProtocolCodecError.commandLifetimeExceeded,
        ]
    }

    private func protocolInvalidArgumentErrors() -> [any Error] {
        [
            HarcProtocolCodecError.inputTooLarge(
                field: "private-field",
                limit: 4,
                actual: 5
            ),
            HarcProtocolCodecError.truncated(field: "private-field"),
            HarcProtocolCodecError.trailingBytes(count: 1),
            HarcProtocolCodecError.invalidMagic(field: "private-field"),
            HarcProtocolCodecError.lengthOutOfRange(
                field: "private-field",
                minimum: 1,
                maximum: 4,
                actual: 5
            ),
            HarcProtocolCodecError.lengthMismatch(
                field: "private-field",
                expected: 4,
                actual: 3
            ),
            HarcProtocolCodecError.invalidTimeRange(field: "private-field"),
            HarcProtocolCodecError.nonCanonicalOrder(field: "private-field"),
            HarcProtocolCodecError.duplicateValue(field: "private-field"),
            HarcProtocolCodecError.invalidText(field: "private-field"),
            HarcProtocolCodecError.invalidEndpoint(field: "private-field"),
            HarcProtocolCodecError.invalidBase64URL,
            HarcProtocolCodecError.invalidPairingURI,
            HarcProtocolCodecError.invalidKeyBinding(field: "private-field"),
            HarcProtocolCodecError.invalidDigest(field: "private-field"),
            HarcProtocolCodecError.invalidSignature,
            HarcProtocolCodecError.payloadHashMismatch,
            HarcProtocolCodecError.unregisteredSignedObject(
                messageType: "private-message",
                payloadType: "private-payload"
            ),
            HarcProtocolCodecError.wrongSignerClass,
            HarcProtocolCodecError.headerPayloadMismatch(
                field: "private-field"
            ),
            HarcProtocolCodecError.missingPayloadBinding(
                field: "private-field"
            ),
            HarcProtocolCodecError.numericOverflow(field: "private-field"),
        ]
    }

    private func protobufPreconditionErrors() -> [any Error] {
        [
            HarcProtobufConversionError.unsupportedRequiredFeature(
                "private-feature"
            ),
            HarcProtobufConversionError.unknownCriticalField(42),
        ]
    }

    private func protobufInvalidArgumentErrors() -> [any Error] {
        [
            HarcProtobufConversionError.inputTooLarge(limit: 4, actual: 5),
            HarcProtobufConversionError.malformedProtobuf,
            HarcProtobufConversionError.missingField("private-field"),
            HarcProtobufConversionError.invalidLength(
                field: "private-field",
                expected: 4,
                actual: 3
            ),
            HarcProtobufConversionError.invalidValue(field: "private-field"),
            HarcProtobufConversionError.integerOutOfRange(
                field: "private-field"
            ),
            HarcProtobufConversionError.unsupportedEnum(
                field: "private-field",
                rawValue: 42
            ),
            HarcProtobufConversionError.nonCanonicalOrder(
                field: "private-field"
            ),
            HarcProtobufConversionError.duplicateValue(field: "private-field"),
            HarcProtobufConversionError.exactPayloadHashMismatch,
            HarcProtobufConversionError.lossyConversion(field: "private-field"),
            HarcProtobufConversionError.inconsistentField("private-field"),
        ]
    }

    private func chunkConflict() throws -> ChunkDeclarationConflict {
        let origin = OriginRecordingID(
            deviceID: try DeviceID(Data(repeating: 0x11, count: 32)),
            recordingUUID: UUID()
        )
        let existing = try chunk(
            origin: origin,
            chunkID: .random(),
            encodedHashByte: 0x21
        )
        let attempted = try chunk(
            origin: origin,
            chunkID: .random(),
            encodedHashByte: 0x22
        )
        return try ChunkDeclarationConflict(
            existing: existing,
            attempted: attempted
        )
    }

    private func chunk(
        origin: OriginRecordingID,
        chunkID: ChunkID,
        encodedHashByte: UInt8
    ) throws -> LogicalChunkDescriptor {
        try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: chunkID,
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 1,
            encoding: .cafALAC,
            encodedByteLength: 1,
            encodedSHA256: EncodedChunkSHA256(
                Data(repeating: encodedHashByte, count: 32)
            ),
            canonicalDecodedByteLength: 2,
            canonicalDecodedSHA256: CanonicalPCMHash(
                Data(repeating: 0x31, count: 32)
            )
        )
    }

    private func assertMapped(
        _ errors: [any Error],
        code: RPCError.Code,
        message: String
    ) {
        for error in errors {
            let mapped = HarcPostSessionGRPCErrorMapper.map(error)
            #expect(mapped.code == code)
            #expect(mapped.message == message)
            #expect(mapped.metadata.isEmpty)
        }
    }
}

private enum UnknownTestError: Error {
    case failure(String)
}
