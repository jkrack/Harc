import CryptoKit
import Foundation
import HarcProtocolWire

/// A processing artifact is usable only after the authenticated signed
/// metadata and the exact HARCPB1 body have been validated as one value. This
/// constructor also supplies the canonical recording length, closing the
/// otherwise intentionally deferred coverage upper bound in a standalone
/// bundle decode.
public struct HarcValidatedProcessingSubmissionV1: Sendable {
    public let authenticatedMetadata: HarcAuthenticatedSignedObjectV1
    public let metadata: HarcExactProtobufPayload<Harc_V1_ProcessingArtifactV1>
    public let bundle: HarcProcessingBundleV1
    public let totalCanonicalFrames: UInt64

    public init(
        authenticatedMetadata: HarcAuthenticatedSignedObjectV1,
        exactBundleBytes: Data,
        totalCanonicalFrames: UInt64,
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1
    ) throws {
        guard case .initialCommandAcceptance = authenticatedMetadata.authenticationPurpose else {
            throw HarcProtocolCodecError.currentGrantRequired
        }
        guard totalCanonicalFrames > 0 else {
            throw HarcProtobufConversionError.invalidValue(
                field: "processingSubmission.totalCanonicalFrames"
            )
        }
        guard case .processingArtifact(let exactMetadata) = authenticatedMetadata.payload else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.metadataType"
            )
        }
        let value = exactMetadata.message
        guard value.exactBundleByteLength == UInt64(exactBundleBytes.count) else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.bundleByteLength"
            )
        }
        let digest = Data(SHA256.hash(data: exactBundleBytes))
        guard value.hasExactBundleSha256,
              value.exactBundleSha256.value == digest else {
            throw HarcProtobufConversionError.exactPayloadHashMismatch
        }

        let bundle = try HarcProcessingBundleV1.decode(
            exactBundleBytes,
            totalCanonicalFrames: totalCanonicalFrames,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        )
        guard value.hasArtifactID,
              bundle.header.hasArtifactID,
              value.artifactID.value == bundle.header.artifactID.value else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.artifactID"
            )
        }
        guard value.hasOriginRecordingID,
              bundle.header.hasOriginRecordingID,
              value.originRecordingID == bundle.header.originRecordingID else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.originRecordingID"
            )
        }
        guard value.hasCanonicalAudioSha256,
              bundle.header.hasCanonicalAudioSha256,
              value.canonicalAudioSha256.value == bundle.header.canonicalAudioSha256.value else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.canonicalAudioSHA256"
            )
        }
        guard value.hasProtocol,
              bundle.header.hasProtocol,
              value.protocol.major == bundle.header.protocol.major,
              value.protocol.minor == bundle.header.protocol.minor else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.protocolVersion"
            )
        }

        let coverageEntries = bundle.entries.compactMap { entry -> Harc_V1_ArtifactCoverageV1? in
            guard case .coverage(_, let value) = entry else { return nil }
            return value.coverage
        }
        guard coverageEntries.count == 1,
              value.hasCoverage,
              coverageEntries[0] == value.coverage else {
            throw HarcProtobufConversionError.inconsistentField(
                "processingSubmission.coverage"
            )
        }

        self.authenticatedMetadata = authenticatedMetadata
        self.metadata = exactMetadata
        self.bundle = bundle
        self.totalCanonicalFrames = totalCanonicalFrames
    }
}
