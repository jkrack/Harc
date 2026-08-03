import Foundation
import HarcDomain

public enum CaptureFinalizationReason: String, Codable, CaseIterable, Sendable {
    case userStopped
    case systemEnded
    case recoveredDurablePrefix
    case storageExhausted
    case writerFailure
}

/// Host-neutral durable capture facts. This value deliberately has no library,
/// authority, grant, upload, filesystem, transcript, or processing identity.
public struct FinalizedCapture: Codable, Equatable, Hashable, Sendable {
    public let producingDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let captureStartedAt: Date
    public let captureEndedAt: Date
    public let captureStartedMonotonicNanoseconds: UInt64
    public let captureEndedMonotonicNanoseconds: UInt64
    public let finalizationReason: CaptureFinalizationReason
    public let canonicalFormat: CanonicalPCMFormat
    public let totalCanonicalFrames: UInt64
    public let totalCanonicalBytes: UInt64
    public let canonicalPCMSHA256: CanonicalPCMHash
    public let discontinuities: [CaptureDiscontinuity]

    public init(
        producingDeviceID: DeviceID,
        originRecordingID: OriginRecordingID,
        captureStartedAt: Date,
        captureEndedAt: Date,
        captureStartedMonotonicNanoseconds: UInt64,
        captureEndedMonotonicNanoseconds: UInt64,
        finalizationReason: CaptureFinalizationReason,
        canonicalFormat: CanonicalPCMFormat = .harcV1,
        totalCanonicalFrames: UInt64,
        totalCanonicalBytes: UInt64,
        canonicalPCMSHA256: CanonicalPCMHash,
        discontinuities: [CaptureDiscontinuity]
    ) throws {
        try TransferValidation.requireFinite(captureStartedAt, field: "FinalizedCapture.captureStartedAt")
        try TransferValidation.requireFinite(captureEndedAt, field: "FinalizedCapture.captureEndedAt")
        guard captureEndedAt >= captureStartedAt else {
            throw TransferValidationError.invalidOrdering(field: "FinalizedCapture wall-clock times")
        }
        guard captureEndedMonotonicNanoseconds >= captureStartedMonotonicNanoseconds else {
            throw TransferValidationError.invalidOrdering(field: "FinalizedCapture monotonic times")
        }
        guard originRecordingID.deviceID == producingDeviceID else {
            throw TransferValidationError.originDeviceMismatch
        }
        try TransferValidation.requireHarcV1(canonicalFormat)
        guard totalCanonicalFrames > 0 else {
            throw TransferValidationError.invalidLength(field: "FinalizedCapture.totalCanonicalFrames", value: totalCanonicalFrames)
        }
        let expectedBytes = try TransferValidation.canonicalByteCount(forFrames: totalCanonicalFrames)
        guard totalCanonicalBytes == expectedBytes else {
            throw TransferValidationError.inconsistentCanonicalByteCount(
                expected: expectedBytes,
                actual: totalCanonicalBytes
            )
        }

        var priorMonotonic: UInt64?
        var priorWallTime: Date?
        for discontinuity in discontinuities {
            guard discontinuity.recordingID == originRecordingID else {
                throw TransferValidationError.discontinuityRecordingMismatch
            }
            guard discontinuity.affectedFrames.endFrameExclusive <= totalCanonicalFrames else {
                throw TransferValidationError.frameRangeOutsideCapture
            }
            if let priorMonotonic {
                guard discontinuity.monotonicTimeNanoseconds >= priorMonotonic else {
                    throw TransferValidationError.invalidOrdering(field: "FinalizedCapture.discontinuities")
                }
                if discontinuity.monotonicTimeNanoseconds == priorMonotonic, let priorWallTime {
                    guard discontinuity.wallTime >= priorWallTime else {
                        throw TransferValidationError.invalidOrdering(field: "FinalizedCapture.discontinuities")
                    }
                }
            }
            priorMonotonic = discontinuity.monotonicTimeNanoseconds
            priorWallTime = discontinuity.wallTime
        }

        self.producingDeviceID = producingDeviceID
        self.originRecordingID = originRecordingID
        self.captureStartedAt = captureStartedAt
        self.captureEndedAt = captureEndedAt
        self.captureStartedMonotonicNanoseconds = captureStartedMonotonicNanoseconds
        self.captureEndedMonotonicNanoseconds = captureEndedMonotonicNanoseconds
        self.finalizationReason = finalizationReason
        self.canonicalFormat = canonicalFormat
        self.totalCanonicalFrames = totalCanonicalFrames
        self.totalCanonicalBytes = totalCanonicalBytes
        self.canonicalPCMSHA256 = canonicalPCMSHA256
        self.discontinuities = discontinuities
    }

    private enum CodingKeys: String, CodingKey {
        case producingDeviceID
        case originRecordingID
        case captureStartedAt
        case captureEndedAt
        case captureStartedMonotonicNanoseconds
        case captureEndedMonotonicNanoseconds
        case finalizationReason
        case canonicalFormat
        case totalCanonicalFrames
        case totalCanonicalBytes
        case canonicalPCMSHA256
        case discontinuities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                producingDeviceID: container.decode(DeviceID.self, forKey: .producingDeviceID),
                originRecordingID: container.decode(OriginRecordingID.self, forKey: .originRecordingID),
                captureStartedAt: container.decode(Date.self, forKey: .captureStartedAt),
                captureEndedAt: container.decode(Date.self, forKey: .captureEndedAt),
                captureStartedMonotonicNanoseconds: container.decode(UInt64.self, forKey: .captureStartedMonotonicNanoseconds),
                captureEndedMonotonicNanoseconds: container.decode(UInt64.self, forKey: .captureEndedMonotonicNanoseconds),
                finalizationReason: container.decode(CaptureFinalizationReason.self, forKey: .finalizationReason),
                canonicalFormat: container.decode(CanonicalPCMFormat.self, forKey: .canonicalFormat),
                totalCanonicalFrames: container.decode(UInt64.self, forKey: .totalCanonicalFrames),
                totalCanonicalBytes: container.decode(UInt64.self, forKey: .totalCanonicalBytes),
                canonicalPCMSHA256: container.decode(CanonicalPCMHash.self, forKey: .canonicalPCMSHA256),
                discontinuities: container.decode([CaptureDiscontinuity].self, forKey: .discontinuities)
            )
        } catch {
            throw TransferValidation.decodingFailure(error, codingPath: decoder.codingPath, description: "Invalid finalized capture.")
        }
    }
}
