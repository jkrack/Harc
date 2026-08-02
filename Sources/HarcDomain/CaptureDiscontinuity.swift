import Foundation

/// Half-open range in canonical PCM frames. Empty ranges are valid for a
/// wall-clock gap that contributed no PCM frames.
public struct CanonicalFrameRange: Codable, Equatable, Hashable, Sendable {
    public let startFrame: UInt64
    public let endFrameExclusive: UInt64

    public init(startFrame: UInt64, endFrameExclusive: UInt64) throws {
        guard endFrameExclusive >= startFrame else {
            throw DomainValidationError.invalidFrameRange(
                startFrame: startFrame,
                endFrameExclusive: endFrameExclusive
            )
        }
        self.startFrame = startFrame
        self.endFrameExclusive = endFrameExclusive
    }

    public var frameCount: UInt64 { endFrameExclusive - startFrame }

    private enum CodingKeys: String, CodingKey {
        case startFrame
        case endFrameExclusive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                startFrame: container.decode(UInt64.self, forKey: .startFrame),
                endFrameExclusive: container.decode(UInt64.self, forKey: .endFrameExclusive)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid canonical frame range.",
                    underlyingError: error
                )
            )
        }
    }
}

public enum CaptureDiscontinuityReason: String, Codable, CaseIterable, Sendable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged
    case engineConfigurationChanged
    case mediaServicesLost
    case mediaServicesReset
    case writerFailure
    case bufferOverrun
    case recovery
}

/// V1 never inserts unrecorded silence. It either preserves the captured PCM
/// timeline or annotates an omitted wall-clock interval.
public enum CaptureCanonicalizationPolicy: String, Codable, CaseIterable, Sendable {
    case preserveCapturedPCM
    case annotateGapWithoutInsertedSilence
}

/// Human-readable route metadata only. No URL or filesystem identity belongs
/// in this portable value.
public struct CaptureRouteDescriptor: Codable, Equatable, Hashable, Sendable {
    public let identifier: String?
    public let name: String?
    public let sampleRateHz: Double?
    public let channelCount: UInt32?

    public init(
        identifier: String? = nil,
        name: String? = nil,
        sampleRateHz: Double? = nil,
        channelCount: UInt32? = nil
    ) throws {
        let identifier = try identifier.map {
            try DomainValidation.nonemptyTrimmed(
                $0,
                field: "CaptureRouteDescriptor.identifier",
                maximum: 512
            )
        }
        let name = try name.map {
            try DomainValidation.nonemptyTrimmed(
                $0,
                field: "CaptureRouteDescriptor.name",
                maximum: 256
            )
        }
        if let sampleRateHz {
            guard sampleRateHz.isFinite, sampleRateHz > 0 else {
                throw DomainValidationError.invalidState(
                    reason: "Capture route sample rate must be finite and positive."
                )
            }
        }
        if let channelCount {
            guard channelCount > 0 else {
                throw DomainValidationError.invalidState(
                    reason: "Capture route channel count must be positive."
                )
            }
        }
        guard identifier != nil || name != nil || sampleRateHz != nil || channelCount != nil else {
            throw DomainValidationError.invalidState(reason: "An empty capture route descriptor is not meaningful.")
        }

        self.identifier = identifier
        self.name = name
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case name
        case sampleRateHz
        case channelCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decodeIfPresent(String.self, forKey: .identifier),
                name: container.decodeIfPresent(String.self, forKey: .name),
                sampleRateHz: container.decodeIfPresent(Double.self, forKey: .sampleRateHz),
                channelCount: container.decodeIfPresent(UInt32.self, forKey: .channelCount)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid capture route descriptor.",
                    underlyingError: error
                )
            )
        }
    }
}

public struct CaptureDiscontinuity: Codable, Equatable, Hashable, Sendable {
    public let recordingID: OriginRecordingID
    public let monotonicTimeNanoseconds: UInt64
    public let wallTime: Date
    public let reason: CaptureDiscontinuityReason
    public let oldRoute: CaptureRouteDescriptor?
    public let newRoute: CaptureRouteDescriptor?
    public let affectedFrames: CanonicalFrameRange
    public let canonicalizationPolicy: CaptureCanonicalizationPolicy

    public init(
        recordingID: OriginRecordingID,
        monotonicTimeNanoseconds: UInt64,
        wallTime: Date,
        reason: CaptureDiscontinuityReason,
        oldRoute: CaptureRouteDescriptor? = nil,
        newRoute: CaptureRouteDescriptor? = nil,
        affectedFrames: CanonicalFrameRange,
        canonicalizationPolicy: CaptureCanonicalizationPolicy
    ) throws {
        try DomainValidation.requireFinite(wallTime, field: "CaptureDiscontinuity.wallTime")
        self.recordingID = recordingID
        self.monotonicTimeNanoseconds = monotonicTimeNanoseconds
        self.wallTime = wallTime
        self.reason = reason
        self.oldRoute = oldRoute
        self.newRoute = newRoute
        self.affectedFrames = affectedFrames
        self.canonicalizationPolicy = canonicalizationPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case recordingID
        case monotonicTimeNanoseconds
        case wallTime
        case reason
        case oldRoute
        case newRoute
        case affectedFrames
        case canonicalizationPolicy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                recordingID: container.decode(OriginRecordingID.self, forKey: .recordingID),
                monotonicTimeNanoseconds: container.decode(UInt64.self, forKey: .monotonicTimeNanoseconds),
                wallTime: container.decode(Date.self, forKey: .wallTime),
                reason: container.decode(CaptureDiscontinuityReason.self, forKey: .reason),
                oldRoute: container.decodeIfPresent(CaptureRouteDescriptor.self, forKey: .oldRoute),
                newRoute: container.decodeIfPresent(CaptureRouteDescriptor.self, forKey: .newRoute),
                affectedFrames: container.decode(CanonicalFrameRange.self, forKey: .affectedFrames),
                canonicalizationPolicy: container.decode(
                    CaptureCanonicalizationPolicy.self,
                    forKey: .canonicalizationPolicy
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid capture discontinuity.",
                    underlyingError: error
                )
            )
        }
    }
}
