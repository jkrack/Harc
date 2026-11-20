import Foundation
import GRDB
import HarcClient
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol
import HarcStore
import HarcTransfer

/// Only closed, reviewed tokens cross the diagnostic boundary. Descriptions,
/// NSError domains/userInfo, associated payloads and type names never enter output.
/// Codes use the existing ProcessingFailure wire/store contract, not retry policy.
struct HarcHostProcessingDiagnostic: Equatable, Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case recordingLookup = "recording_lookup"
        case resourceAdmission = "resource_admission"
        case daemonPreparation = "daemon_preparation"
        case canonicalValidation = "canonical_validation"
        case processingStart = "processing_start"
        case audioBeforeTranscription = "audio_before_transcription"
        case transcription = "transcription"
        case audioAfterTranscription = "audio_after_transcription"
        case transcriptEncoding = "transcript_encoding"
        case transcriptStaging = "transcript_staging"
        case speakerEvidence = "speaker_evidence"
        case speakerMatching = "speaker_matching"
        case speakerOutcome = "speaker_outcome"
        case audioBeforePublication = "audio_before_publication"
        case projectionPublication = "projection_publication"

        var summary: String {
            switch self {
            case .recordingLookup: "Reading the canonical Library row"
            case .resourceAdmission: "Checking local audio availability"
            case .daemonPreparation: "Preparing the local transcription engine"
            case .canonicalValidation: "Revalidating signed canonical evidence"
            case .processingStart: "Starting the durable processing state"
            case .audioBeforeTranscription: "Checking audio identity before transcription"
            case .transcription: "Transcribing canonical audio"
            case .audioAfterTranscription: "Checking audio identity after transcription"
            case .transcriptEncoding: "Encoding the derived transcript"
            case .transcriptStaging: "Staging the derived transcript"
            case .speakerEvidence: "Retaining bound speaker evidence"
            case .speakerMatching: "Matching bound speaker evidence"
            case .speakerOutcome: "Preparing the bound speaker outcome"
            case .audioBeforePublication: "Checking audio identity before publication"
            case .projectionPublication: "Publishing the derived projection"
            }
        }
    }

    enum Cause: String, CaseIterable, Sendable {
        case unknown
        case encodingInvalidValue = "encoding.invalid_value"
        case decodingTypeMismatch = "decoding.type_mismatch"
        case decodingValueMissing = "decoding.value_missing"
        case decodingKeyMissing = "decoding.key_missing"
        case decodingCorrupt = "decoding.corrupt"
        case sqliteBusy = "sqlite.busy"
        case sqliteLocked = "sqlite.locked"
        case sqliteFull = "sqlite.full"
        case sqliteCorrupt = "sqlite.corrupt"
        case sqliteNotDatabase = "sqlite.not_database"
        case sqliteReadOnly = "sqlite.read_only"
        case sqliteCannotOpen = "sqlite.cannot_open"
        case sqliteConstraint = "sqlite.constraint"
        case sqliteIO = "sqlite.io"
        case sqliteSync = "sqlite.sync"
        case sqliteOther = "sqlite.other"
        case posixNoSpace = "posix.no_space"
        case posixPermission = "posix.permission"
        case posixMissing = "posix.missing"
        case posixIO = "posix.io"
        case posixOther = "posix.other"
        case cocoaMissing = "cocoa.missing"
        case cocoaReadPermission = "cocoa.read_permission"
        case cocoaWritePermission = "cocoa.write_permission"
        case cocoaNoSpace = "cocoa.no_space"
        case cocoaReadCorrupt = "cocoa.read_corrupt"
        case cocoaOther = "cocoa.other"
        case cancelled
        case bindingChanged = "worker.binding_changed"
        case hostDatabaseOpenFailed = "host.database_open_failed"
        case hostMigrationFailed = "host.migration_failed"
        case hostDatabaseFailure = "host.database_failure"
        case hostMetadataMismatch = "host.metadata_mismatch"
        case hostInvalidDigestLength = "host.invalid_digest_length"
        case hostInsufficientFreeSpace = "host.insufficient_free_space"
        case hostVolumeCapacityUnavailable = "host.volume_capacity_unavailable"
        case hostManifestEvidenceRequired = "host.manifest_evidence_required"
        case hostIncompleteCanonicalUpload = "host.incomplete_canonical_upload"
        case hostPublicationRecoveryRequired = "host.publication_recovery_required"
        case hostPublicationCheckpointConflict = "host.publication_checkpoint_conflict"
        case hostCanonicalPublicationAlreadyInProgress = "host.canonical_publication_already_in_progress"
        case hostQualifiedDecoderUnavailable = "host.qualified_decoder_unavailable"
        case hostFixtureDecoderForbidden = "host.fixture_decoder_forbidden"
        case hostInvalidCanonicalFrameCount = "host.invalid_canonical_frame_count"
        case hostDecodedLengthMismatch = "host.decoded_length_mismatch"
        case hostCanonicalHashMismatch = "host.canonical_hash_mismatch"
        case hostCanonicalArtifactIdentityMismatch = "host.canonical_artifact_identity_mismatch"
        case hostClassicRIFFSizeExceeded = "host.classic_riffsize_exceeded"
        case hostUnsafePublicationRoot = "host.unsafe_publication_root"
        case hostUnsafePublicationPath = "host.unsafe_publication_path"
        case hostCanonicalDestinationExists = "host.canonical_destination_exists"
        case hostInvalidCanonicalWAV = "host.invalid_canonical_wav"
        case hostProvenanceSidecarConflict = "host.provenance_sidecar_conflict"
        case hostPublicationIO = "host.publication_io"
        case hostProcessingSchedulerUnavailable = "host.processing_scheduler_unavailable"
        case hostOther = "host.other"
        case storeDatabaseOpenFailed = "store.database_open_failed"
        case storeMigrationFailed = "store.migration_failed"
        case storeNotFound = "store.not_found"
        case storeOriginIdentityConflict = "store.origin_identity_conflict"
        case storeCanonicalPCMHashConflict = "store.canonical_pcmhash_conflict"
        case storeWriterLeaseUnavailable = "store.writer_lease_unavailable"
        case storeUnsafeWriterLeasePath = "store.unsafe_writer_lease_path"
        case storeStaleHostWriterMarker = "store.stale_host_writer_marker"
        case storeHostWriterTupleMismatch = "store.host_writer_tuple_mismatch"
        case storeHostWriterCapabilityRequired = "store.host_writer_capability_required"
        case storeCanonicalRecordingIdentityConflict = "store.canonical_recording_identity_conflict"
        case storeCanonicalRecordingPathConflict = "store.canonical_recording_path_conflict"
        case storeCanonicalArtifactIdentityMismatch = "store.canonical_artifact_identity_mismatch"
        case storeChangeCursorOverflow = "store.change_cursor_overflow"
        case storeRevisionConflict = "store.revision_conflict"
        case storeRevisionOverflow = "store.revision_overflow"
        case storeInvalidData = "store.invalid_data"
        case storeReadFailed = "store.read_failed"
        case storeWriteFailed = "store.write_failed"
        case clientDaemonNotReachable = "client.daemon_not_reachable"
        case clientDaemonLaunchFailed = "client.daemon_launch_failed"
        case clientIpcEncodeFailed = "client.ipc_encode_failed"
        case clientIpcDecodeFailed = "client.ipc_decode_failed"
        case clientTranscribeFailed = "client.transcribe_failed"
        case daemonModelNotLoaded = "daemon.model_not_loaded"
        case daemonAudioLoadFailed = "daemon.audio_load_failed"
        case daemonTranscriptionFailed = "daemon.transcription_failed"
        case daemonSocketError = "daemon.socket_error"
        case daemonTranscribeFailed = "daemon.transcribe_failed"
        case daemonDiarizerUnavailable = "daemon.diarizer_unavailable"
        case daemonDiarizeFailed = "daemon.diarize_failed"
        case clientChunkerFailed = "client.chunker_failed"
        case clientTimeout = "client.timeout"
        case protocolInputTooLarge = "protocol.input_too_large"
        case protocolTruncated = "protocol.truncated"
        case protocolTrailingBytes = "protocol.trailing_bytes"
        case protocolInvalidMagic = "protocol.invalid_magic"
        case protocolLengthOutOfRange = "protocol.length_out_of_range"
        case protocolLengthMismatch = "protocol.length_mismatch"
        case protocolUnsupportedProtocolMajor = "protocol.unsupported_protocol_major"
        case protocolUnsupportedProtocolMinor = "protocol.unsupported_protocol_minor"
        case protocolInvalidTimeRange = "protocol.invalid_time_range"
        case protocolExpired = "protocol.expired"
        case protocolNonCanonicalOrder = "protocol.non_canonical_order"
        case protocolDuplicateValue = "protocol.duplicate_value"
        case protocolInvalidText = "protocol.invalid_text"
        case protocolInvalidEndpoint = "protocol.invalid_endpoint"
        case protocolInvalidBase64URL = "protocol.invalid_base64_url"
        case protocolInvalidPairingURI = "protocol.invalid_pairing_uri"
        case protocolInvalidKeyBinding = "protocol.invalid_key_binding"
        case protocolInvalidDigest = "protocol.invalid_digest"
        case protocolInvalidSignature = "protocol.invalid_signature"
        case protocolPayloadHashMismatch = "protocol.payload_hash_mismatch"
        case protocolUnregisteredSignedObject = "protocol.unregistered_signed_object"
        case protocolWrongSignerClass = "protocol.wrong_signer_class"
        case protocolHeaderPayloadMismatch = "protocol.header_payload_mismatch"
        case protocolMissingPayloadBinding = "protocol.missing_payload_binding"
        case protocolCurrentGrantRequired = "protocol.current_grant_required"
        case protocolStaleGrant = "protocol.stale_grant"
        case protocolCommandExpired = "protocol.command_expired"
        case protocolCommandLifetimeExceeded = "protocol.command_lifetime_exceeded"
        case protocolInvalidSASDictionary = "protocol.invalid_sasdictionary"
        case protocolNumericOverflow = "protocol.numeric_overflow"
        case domainInvalidDigestLength = "domain.invalid_digest_length"
        case domainZeroEntityRevision = "domain.zero_entity_revision"
        case domainInvalidSignedValue = "domain.invalid_signed_value"
        case domainNumericOverflow = "domain.numeric_overflow"
        case domainInvalidFrameRange = "domain.invalid_frame_range"
        case domainInvalidDate = "domain.invalid_date"
        case domainEmptyField = "domain.empty_field"
        case domainFieldTooLong = "domain.field_too_long"
        case domainInvalidCode = "domain.invalid_code"
        case domainInvalidState = "domain.invalid_state"
        case domainInvalidOrdering = "domain.invalid_ordering"
        case domainDuplicateIdentifier = "domain.duplicate_identifier"
        case domainInconsistentHostIdentity = "domain.inconsistent_host_identity"
        case domainMatchingConflictRevisions = "domain.matching_conflict_revisions"
        case transferInvalidDigestLength = "transfer.invalid_digest_length"
        case transferInvalidLength = "transfer.invalid_length"
        case transferExceedsLimit = "transfer.exceeds_limit"
        case transferInvalidDate = "transfer.invalid_date"
        case transferInvalidOrdering = "transfer.invalid_ordering"
        case transferDuplicateIdentifier = "transfer.duplicate_identifier"
        case transferNumericOverflow = "transfer.numeric_overflow"
        case transferInvalidCanonicalFormat = "transfer.invalid_canonical_format"
        case transferOriginDeviceMismatch = "transfer.origin_device_mismatch"
        case transferDiscontinuityRecordingMismatch = "transfer.discontinuity_recording_mismatch"
        case transferFrameRangeOutsideCapture = "transfer.frame_range_outside_capture"
        case transferInconsistentCanonicalByteCount = "transfer.inconsistent_canonical_byte_count"
        case transferIncompatibleCodecAndContainer = "transfer.incompatible_codec_and_container"
        case transferInvalidCodecParameters = "transfer.invalid_codec_parameters"
        case transferRawPCMRestrictedToFixtures = "transfer.raw_pcmrestricted_to_fixtures"
        case transferInvalidCapabilityIdentifier = "transfer.invalid_capability_identifier"
        case transferProfileMismatch = "transfer.profile_mismatch"
        case transferChunkConflict = "transfer.chunk_conflict"
        case transferDeclarationBlocked = "transfer.declaration_blocked"
        case transferDeclarationClosed = "transfer.declaration_closed"
        case transferNonContiguousDeclaration = "transfer.non_contiguous_declaration"
        case transferIncompleteChunkCoverage = "transfer.incomplete_chunk_coverage"
        case transferInvalidUploadAttempt = "transfer.invalid_upload_attempt"
        case transferStaleUploadGeneration = "transfer.stale_upload_generation"
        case transferUploadExpired = "transfer.upload_expired"
        case transferUploadNotExpired = "transfer.upload_not_expired"
        case transferUploadTerminal = "transfer.upload_terminal"
        case transferInvalidOutboxTransition = "transfer.invalid_outbox_transition"
        case transferReceiptEvidenceRequired = "transfer.receipt_evidence_required"
        case transferEvidenceBindingMismatch = "transfer.evidence_binding_mismatch"
        case transferReconciliationMismatch = "transfer.reconciliation_mismatch"
        case transferEmptyExactObject = "transfer.empty_exact_object"
        case transferWrongExactObjectKind = "transfer.wrong_exact_object_kind"
        case protobufInputTooLarge = "protobuf.input_too_large"
        case protobufMalformedProtobuf = "protobuf.malformed_protobuf"
        case protobufMissingField = "protobuf.missing_field"
        case protobufInvalidLength = "protobuf.invalid_length"
        case protobufInvalidValue = "protobuf.invalid_value"
        case protobufIntegerOutOfRange = "protobuf.integer_out_of_range"
        case protobufUnsupportedEnum = "protobuf.unsupported_enum"
        case protobufNonCanonicalOrder = "protobuf.non_canonical_order"
        case protobufDuplicateValue = "protobuf.duplicate_value"
        case protobufUnsupportedRequiredFeature = "protobuf.unsupported_required_feature"
        case protobufUnknownCriticalField = "protobuf.unknown_critical_field"
        case protobufExactPayloadHashMismatch = "protobuf.exact_payload_hash_mismatch"
        case protobufLossyConversion = "protobuf.lossy_conversion"
        case protobufInconsistentField = "protobuf.inconsistent_field"
        case identityInvalidDigestLength = "identity.invalid_digest_length"
        case identityInvalidPublicKeyLength = "identity.invalid_public_key_length"
        case identityInvalidPublicKeyPrefix = "identity.invalid_public_key_prefix"
        case identityInvalidPublicKey = "identity.invalid_public_key"
        case identityInvalidSignatureLength = "identity.invalid_signature_length"
        case identityInvalidSignatureScalar = "identity.invalid_signature_scalar"
        case identitySignatureNotLowS = "identity.signature_not_low_s"
        case identityInvalidPrivateKey = "identity.invalid_private_key"

        static func classify(_ error: any Error) -> Self {
            if let error = error as? HostProcessingWorkerError {
                switch error {
                case .canonicalBindingChanged: return .bindingChanged
                case .canonicalRevalidationFailed(let cause): return cause
                }
            }
            if error is CancellationError { return .cancelled }
            if let error = error as? HarcHostError {
                switch error {
                case .databaseOpenFailed: return .hostDatabaseOpenFailed
                case .migrationFailed: return .hostMigrationFailed
                case .databaseFailure: return .hostDatabaseFailure
                case .metadataMismatch: return .hostMetadataMismatch
                case .invalidDigestLength: return .hostInvalidDigestLength
                case .insufficientFreeSpace: return .hostInsufficientFreeSpace
                case .volumeCapacityUnavailable: return .hostVolumeCapacityUnavailable
                case .manifestEvidenceRequired: return .hostManifestEvidenceRequired
                case .incompleteCanonicalUpload: return .hostIncompleteCanonicalUpload
                case .publicationRecoveryRequired: return .hostPublicationRecoveryRequired
                case .publicationCheckpointConflict: return .hostPublicationCheckpointConflict
                case .canonicalPublicationAlreadyInProgress: return .hostCanonicalPublicationAlreadyInProgress
                case .qualifiedDecoderUnavailable: return .hostQualifiedDecoderUnavailable
                case .fixtureDecoderForbidden: return .hostFixtureDecoderForbidden
                case .invalidCanonicalFrameCount: return .hostInvalidCanonicalFrameCount
                case .decodedLengthMismatch: return .hostDecodedLengthMismatch
                case .canonicalHashMismatch: return .hostCanonicalHashMismatch
                case .canonicalArtifactIdentityMismatch: return .hostCanonicalArtifactIdentityMismatch
                case .classicRIFFSizeExceeded: return .hostClassicRIFFSizeExceeded
                case .unsafePublicationRoot: return .hostUnsafePublicationRoot
                case .unsafePublicationPath: return .hostUnsafePublicationPath
                case .canonicalDestinationExists: return .hostCanonicalDestinationExists
                case .invalidCanonicalWAV: return .hostInvalidCanonicalWAV
                case .provenanceSidecarConflict: return .hostProvenanceSidecarConflict
                case .publicationIO: return .hostPublicationIO
                case .processingSchedulerUnavailable: return .hostProcessingSchedulerUnavailable
                default: return .hostOther
                }
            }
            if let error = error as? StoreError {
                switch error {
                case .databaseOpenFailed: return .storeDatabaseOpenFailed
                case .migrationFailed: return .storeMigrationFailed
                case .notFound: return .storeNotFound
                case .originIdentityConflict: return .storeOriginIdentityConflict
                case .canonicalPCMHashConflict: return .storeCanonicalPCMHashConflict
                case .writerLeaseUnavailable: return .storeWriterLeaseUnavailable
                case .unsafeWriterLeasePath: return .storeUnsafeWriterLeasePath
                case .staleHostWriterMarker: return .storeStaleHostWriterMarker
                case .hostWriterTupleMismatch: return .storeHostWriterTupleMismatch
                case .hostWriterCapabilityRequired: return .storeHostWriterCapabilityRequired
                case .canonicalRecordingIdentityConflict: return .storeCanonicalRecordingIdentityConflict
                case .canonicalRecordingPathConflict: return .storeCanonicalRecordingPathConflict
                case .canonicalArtifactIdentityMismatch: return .storeCanonicalArtifactIdentityMismatch
                case .changeCursorOverflow: return .storeChangeCursorOverflow
                case .revisionConflict: return .storeRevisionConflict
                case .revisionOverflow: return .storeRevisionOverflow
                case .invalidData: return .storeInvalidData
                case .readFailed: return .storeReadFailed
                case .writeFailed: return .storeWriteFailed
                }
            }
            if let error = error as? ClientError {
                switch error {
                case .daemonNotReachable: return .clientDaemonNotReachable
                case .daemonLaunchFailed: return .clientDaemonLaunchFailed
                case .ipcEncodeFailed: return .clientIpcEncodeFailed
                case .ipcDecodeFailed: return .clientIpcDecodeFailed
                case .transcribeFailed(let code, _):
                    // Compare to reviewed constants; never retain an arbitrary
                    // daemon code or message, even if it looks like a token.
                    switch code {
                    case "model_not_loaded": return .daemonModelNotLoaded
                    case "audio_load_failed": return .daemonAudioLoadFailed
                    case "transcription_failed": return .daemonTranscriptionFailed
                    case "socket_error": return .daemonSocketError
                    case "transcribe_failed": return .daemonTranscribeFailed
                    case "diarizer_unavailable": return .daemonDiarizerUnavailable
                    case "diarize_failed": return .daemonDiarizeFailed
                    default: return .clientTranscribeFailed
                    }
                case .chunkerFailed: return .clientChunkerFailed
                case .timeout: return .clientTimeout
                }
            }
            if let error = error as? HarcProtocolCodecError {
                switch error {
                case .inputTooLarge: return .protocolInputTooLarge
                case .truncated: return .protocolTruncated
                case .trailingBytes: return .protocolTrailingBytes
                case .invalidMagic: return .protocolInvalidMagic
                case .lengthOutOfRange: return .protocolLengthOutOfRange
                case .lengthMismatch: return .protocolLengthMismatch
                case .unsupportedProtocolMajor: return .protocolUnsupportedProtocolMajor
                case .unsupportedProtocolMinor: return .protocolUnsupportedProtocolMinor
                case .invalidTimeRange: return .protocolInvalidTimeRange
                case .expired: return .protocolExpired
                case .nonCanonicalOrder: return .protocolNonCanonicalOrder
                case .duplicateValue: return .protocolDuplicateValue
                case .invalidText: return .protocolInvalidText
                case .invalidEndpoint: return .protocolInvalidEndpoint
                case .invalidBase64URL: return .protocolInvalidBase64URL
                case .invalidPairingURI: return .protocolInvalidPairingURI
                case .invalidKeyBinding: return .protocolInvalidKeyBinding
                case .invalidDigest: return .protocolInvalidDigest
                case .invalidSignature: return .protocolInvalidSignature
                case .payloadHashMismatch: return .protocolPayloadHashMismatch
                case .unregisteredSignedObject: return .protocolUnregisteredSignedObject
                case .wrongSignerClass: return .protocolWrongSignerClass
                case .headerPayloadMismatch: return .protocolHeaderPayloadMismatch
                case .missingPayloadBinding: return .protocolMissingPayloadBinding
                case .currentGrantRequired: return .protocolCurrentGrantRequired
                case .staleGrant: return .protocolStaleGrant
                case .commandExpired: return .protocolCommandExpired
                case .commandLifetimeExceeded: return .protocolCommandLifetimeExceeded
                case .invalidSASDictionary: return .protocolInvalidSASDictionary
                case .numericOverflow: return .protocolNumericOverflow
                }
            }
            if let error = error as? DomainValidationError {
                switch error {
                case .invalidDigestLength: return .domainInvalidDigestLength
                case .zeroEntityRevision: return .domainZeroEntityRevision
                case .invalidSignedValue: return .domainInvalidSignedValue
                case .numericOverflow: return .domainNumericOverflow
                case .invalidFrameRange: return .domainInvalidFrameRange
                case .invalidDate: return .domainInvalidDate
                case .emptyField: return .domainEmptyField
                case .fieldTooLong: return .domainFieldTooLong
                case .invalidCode: return .domainInvalidCode
                case .invalidState: return .domainInvalidState
                case .invalidOrdering: return .domainInvalidOrdering
                case .duplicateIdentifier: return .domainDuplicateIdentifier
                case .inconsistentHostIdentity: return .domainInconsistentHostIdentity
                case .matchingConflictRevisions: return .domainMatchingConflictRevisions
                }
            }
            if let error = error as? TransferValidationError {
                switch error {
                case .invalidDigestLength: return .transferInvalidDigestLength
                case .invalidLength: return .transferInvalidLength
                case .exceedsLimit: return .transferExceedsLimit
                case .invalidDate: return .transferInvalidDate
                case .invalidOrdering: return .transferInvalidOrdering
                case .duplicateIdentifier: return .transferDuplicateIdentifier
                case .numericOverflow: return .transferNumericOverflow
                case .invalidCanonicalFormat: return .transferInvalidCanonicalFormat
                case .originDeviceMismatch: return .transferOriginDeviceMismatch
                case .discontinuityRecordingMismatch: return .transferDiscontinuityRecordingMismatch
                case .frameRangeOutsideCapture: return .transferFrameRangeOutsideCapture
                case .inconsistentCanonicalByteCount: return .transferInconsistentCanonicalByteCount
                case .incompatibleCodecAndContainer: return .transferIncompatibleCodecAndContainer
                case .invalidCodecParameters: return .transferInvalidCodecParameters
                case .rawPCMRestrictedToFixtures: return .transferRawPCMRestrictedToFixtures
                case .invalidCapabilityIdentifier: return .transferInvalidCapabilityIdentifier
                case .profileMismatch: return .transferProfileMismatch
                case .chunkConflict: return .transferChunkConflict
                case .declarationBlocked: return .transferDeclarationBlocked
                case .declarationClosed: return .transferDeclarationClosed
                case .nonContiguousDeclaration: return .transferNonContiguousDeclaration
                case .incompleteChunkCoverage: return .transferIncompleteChunkCoverage
                case .invalidUploadAttempt: return .transferInvalidUploadAttempt
                case .staleUploadGeneration: return .transferStaleUploadGeneration
                case .uploadExpired: return .transferUploadExpired
                case .uploadNotExpired: return .transferUploadNotExpired
                case .uploadTerminal: return .transferUploadTerminal
                case .invalidOutboxTransition: return .transferInvalidOutboxTransition
                case .receiptEvidenceRequired: return .transferReceiptEvidenceRequired
                case .evidenceBindingMismatch: return .transferEvidenceBindingMismatch
                case .reconciliationMismatch: return .transferReconciliationMismatch
                case .emptyExactObject: return .transferEmptyExactObject
                case .wrongExactObjectKind: return .transferWrongExactObjectKind
                }
            }
            if let error = error as? HarcProtobufConversionError {
                switch error {
                case .inputTooLarge: return .protobufInputTooLarge
                case .malformedProtobuf: return .protobufMalformedProtobuf
                case .missingField: return .protobufMissingField
                case .invalidLength: return .protobufInvalidLength
                case .invalidValue: return .protobufInvalidValue
                case .integerOutOfRange: return .protobufIntegerOutOfRange
                case .unsupportedEnum: return .protobufUnsupportedEnum
                case .nonCanonicalOrder: return .protobufNonCanonicalOrder
                case .duplicateValue: return .protobufDuplicateValue
                case .unsupportedRequiredFeature: return .protobufUnsupportedRequiredFeature
                case .unknownCriticalField: return .protobufUnknownCriticalField
                case .exactPayloadHashMismatch: return .protobufExactPayloadHashMismatch
                case .lossyConversion: return .protobufLossyConversion
                case .inconsistentField: return .protobufInconsistentField
                }
            }
            if let error = error as? IdentityCryptoError {
                switch error {
                case .invalidDigestLength: return .identityInvalidDigestLength
                case .invalidPublicKeyLength: return .identityInvalidPublicKeyLength
                case .invalidPublicKeyPrefix: return .identityInvalidPublicKeyPrefix
                case .invalidPublicKey: return .identityInvalidPublicKey
                case .invalidSignatureLength: return .identityInvalidSignatureLength
                case .invalidSignatureScalar: return .identityInvalidSignatureScalar
                case .signatureNotLowS: return .identitySignatureNotLowS
                case .invalidPrivateKey: return .identityInvalidPrivateKey
                }
            }
            if let error = error as? EncodingError {
                switch error {
                case .invalidValue: return .encodingInvalidValue
                @unknown default: return .unknown
                }
            }
            if let error = error as? DecodingError {
                switch error {
                case .typeMismatch: return .decodingTypeMismatch
                case .valueNotFound: return .decodingValueMissing
                case .keyNotFound: return .decodingKeyMissing
                case .dataCorrupted: return .decodingCorrupt
                @unknown default: return .unknown
                }
            }
            if let error = error as? DatabaseError {
                switch error.extendedResultCode {
                case .SQLITE_IOERR_FSYNC, .SQLITE_IOERR_DIR_FSYNC: return .sqliteSync
                default: break
                }
                switch error.resultCode {
                case .SQLITE_BUSY: return .sqliteBusy
                case .SQLITE_LOCKED: return .sqliteLocked
                case .SQLITE_FULL: return .sqliteFull
                case .SQLITE_CORRUPT: return .sqliteCorrupt
                case .SQLITE_NOTADB: return .sqliteNotDatabase
                case .SQLITE_READONLY: return .sqliteReadOnly
                case .SQLITE_CANTOPEN: return .sqliteCannotOpen
                case .SQLITE_CONSTRAINT: return .sqliteConstraint
                case .SQLITE_IOERR: return .sqliteIO
                default: return .sqliteOther
                }
            }
            // Foundation erases native POSIXError/CocoaError to NSError at
            // the Error boundary. Admit only the concrete Foundation class:
            // subclasses may override accessors, and bridging an arbitrary
            // CustomNSError could evaluate userInfo. Compare stored domain/code
            // only to this finite allowlist; never retain their original values.
            if type(of: error) == NSError.self {
                let foundationError = error as NSError
                switch foundationError.domain {
                case NSPOSIXErrorDomain:
                    switch foundationError.code {
                    case Int(POSIXError.ENOSPC.rawValue): return .posixNoSpace
                    case Int(POSIXError.EACCES.rawValue), Int(POSIXError.EPERM.rawValue): return .posixPermission
                    case Int(POSIXError.ENOENT.rawValue): return .posixMissing
                    case Int(POSIXError.EIO.rawValue): return .posixIO
                    default: return .posixOther
                    }
                case NSCocoaErrorDomain:
                    switch foundationError.code {
                    case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue: return .cocoaMissing
                    case CocoaError.fileReadNoPermission.rawValue: return .cocoaReadPermission
                    case CocoaError.fileWriteNoPermission.rawValue: return .cocoaWritePermission
                    case CocoaError.fileWriteOutOfSpace.rawValue: return .cocoaNoSpace
                    case CocoaError.fileReadCorruptFile.rawValue: return .cocoaReadCorrupt
                    default: return .cocoaOther
                    }
                default: return .unknown
                }
            }
            // In particular, do not bridge an arbitrary error to NSError or
            // follow its underlying error. Unknown failures remain redacted.
            return .unknown
        }

        var recovery: String {
            switch self {
            case .cancelled:
                "Processing was interrupted; retry when the Host is available."
            case .bindingChanged, .hostCanonicalArtifactIdentityMismatch:
                "The canonical binding changed; review local receipt recovery before retrying."
            case .storeCanonicalArtifactIdentityMismatch:
                "The audio identity changed during processing; a fresh validation is required."
            case .hostCanonicalHashMismatch, .hostInvalidCanonicalWAV, .hostDecodedLengthMismatch:
                "Canonical audio validation failed; inspect the protected local audio and receipt before retrying."
            case .hostPublicationRecoveryRequired, .hostManifestEvidenceRequired:
                "Required durable evidence is unavailable; review local receipt recovery before retrying."
            case .protocolInvalidSignature, .protocolPayloadHashMismatch, .protocolInvalidKeyBinding,
                 .protocolHeaderPayloadMismatch, .protocolWrongSignerClass:
                "Signed evidence authentication failed; inspect the retained manifest and receipt before retrying."
            case .clientDaemonLaunchFailed, .clientDaemonNotReachable, .clientTimeout:
                "Check the local transcription engine's readiness, then retry."
            case .daemonModelNotLoaded:
                "The transcription model is not loaded; check local model readiness, then retry."
            case .daemonDiarizerUnavailable, .daemonDiarizeFailed:
                "Local speaker processing failed; check the diarization model, then retry."
            case .daemonAudioLoadFailed:
                "The local engine could not read the audio; check local audio availability before retrying."
            case .daemonSocketError:
                "The local engine connection failed; check engine readiness, then retry."
            case .clientTranscribeFailed, .daemonTranscriptionFailed, .daemonTranscribeFailed:
                "The local engine rejected transcription; check model readiness, then retry."
            case .clientIpcEncodeFailed, .clientIpcDecodeFailed:
                "The local engine could not exchange a valid response; check app and engine compatibility, then retry."
            case .sqliteBusy, .sqliteLocked:
                "The Library database is busy; allow current local work to finish, then retry."
            case .sqliteCorrupt, .sqliteNotDatabase:
                "The Library database could not be validated; inspect local Library recovery before retrying."
            case .sqliteSync, .sqliteIO, .posixIO:
                "A local storage operation failed; check the storage device before retrying."
            case .cocoaReadPermission, .cocoaWritePermission, .posixPermission, .sqliteReadOnly:
                "Check local Library and audio access permissions before retrying."
            case .cocoaMissing, .posixMissing, .sqliteCannotOpen:
                "Required local data is unavailable; check Library and audio availability before retrying."
            case .hostInsufficientFreeSpace, .hostVolumeCapacityUnavailable, .sqliteFull, .posixNoSpace, .cocoaNoSpace:
                "Check local storage availability before retrying."
            default:
                "Inspect the reported phase and failure code before retrying local processing."
            }
        }
    }

    let phase: Phase
    let cause: Cause

    init(phase: Phase, error: any Error) {
        self.init(phase: phase, cause: Cause.classify(error))
    }

    init(phase: Phase, cause: Cause) {
        self.phase = phase
        self.cause = cause
    }

    var failure: ProcessingFailure {
        // The complete finite catalog is checked against ProcessingFailure's
        // limits in tests. No runtime data participates in either string.
        try! ProcessingFailure(code: "host.processing.\(phase.rawValue).\(cause.rawValue)",
            message: "\(phase.summary) failed. \(cause.recovery)")
    }

    var logLine: String {
        "harc-host: canonical processing failed [\(failure.code)] \(failure.message!)\n"
    }
}
