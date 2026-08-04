import CryptoKit
import Darwin
import Foundation
import HarcDomain

public enum HarcMobileCaptureFinalizationReason: String, Codable, Sendable {
    case userStopped
    case systemEnded
    case recoveredDurablePrefix
    case storageExhausted
    case writerFailure
}

public struct HarcMobileFinalizedMaster: Codable, Equatable, Sendable {
    public let producingDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let masterFileURL: URL
    public let captureStartedAt: Date
    public let captureEndedAt: Date
    public let captureStartedMonotonicNanoseconds: UInt64
    public let captureEndedMonotonicNanoseconds: UInt64
    public let finalizationReason: HarcMobileCaptureFinalizationReason
    public let totalCanonicalFrames: UInt64
    public let canonicalPCMSHA256: CanonicalPCMHash
    public let discontinuities: [CaptureDiscontinuity]

    public var totalCanonicalBytes: UInt64 { totalCanonicalFrames * 2 }
}

private struct HarcMobileCaptureCheckpoint: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let producingDeviceID: DeviceID
    let originRecordingID: OriginRecordingID
    let captureStartedAt: Date
    let captureStartedMonotonicNanoseconds: UInt64
    let durableEndedAt: Date
    let durableEndedMonotonicNanoseconds: UInt64
    let durableCanonicalFrames: UInt64
    let discontinuities: [CaptureDiscontinuity]
}

/// Serial durable writer for Harc's canonical mobile master.
///
/// Callers own serialization. The active file is a validly shaped WAV with a
/// placeholder header and append-only canonical PCM. At most five seconds may
/// pass between durable checkpoints. Recovery truncates bytes beyond the last
/// atomically persisted checkpoint before publishing a finalized master.
public final class HarcMobileDurableMasterWriter {
    public static let canonicalSampleRate: UInt32 = 16_000
    public static let checkpointFrames: UInt64 = 5 * 16_000
    private static let wavHeaderBytes: UInt64 = 44
    private static let maximumDiscontinuities = 4_096

    public let producingDeviceID: DeviceID
    public let originRecordingID: OriginRecordingID
    public let captureStartedAt: Date
    public let captureStartedMonotonicNanoseconds: UInt64

    private let locations: HarcMobileCaptureLocations
    private let attributes: any HarcMobileCaptureStorageAttributeApplying
    private let partialURL: URL
    private let checkpointURL: URL
    private var descriptor: Int32
    private var hasher = SHA256()
    private var totalFrames: UInt64 = 0
    private var durableFrames: UInt64 = 0
    private var lastEndedAt: Date
    private var lastEndedMonotonicNanoseconds: UInt64
    private var discontinuities: [CaptureDiscontinuity] = []
    private var closed = false

    public init(
        locations: HarcMobileCaptureLocations,
        producingDeviceID: DeviceID,
        recordingUUID: UUID = UUID(),
        captureStartedAt: Date = Date(),
        captureStartedMonotonicNanoseconds: UInt64,
        attributes: any HarcMobileCaptureStorageAttributeApplying =
            FoundationHarcMobileCaptureStorageAttributes()
    ) throws {
        self.locations = locations
        self.attributes = attributes
        self.producingDeviceID = producingDeviceID
        originRecordingID = OriginRecordingID(
            deviceID: producingDeviceID,
            recordingUUID: recordingUUID
        )
        self.captureStartedAt = captureStartedAt
        self.captureStartedMonotonicNanoseconds =
            captureStartedMonotonicNanoseconds
        lastEndedAt = captureStartedAt
        lastEndedMonotonicNanoseconds = captureStartedMonotonicNanoseconds
        partialURL = locations.partialMasterURL(recordingUUID: recordingUUID)
        checkpointURL = locations.checkpointURL(recordingUUID: recordingUUID)

        try locations.prepare(attributes: attributes)
        descriptor = try HarcMobileCaptureFileSystem.createExclusiveFile(
            partialURL
        )
        do {
            try HarcMobileCaptureFileSystem.writeAll(
                Data(repeating: 0, count: Int(Self.wavHeaderBytes)),
                to: descriptor
            )
            try attributes.applyAndVerify(.activeMaster, to: partialURL)
            try checkpoint(force: true)
        } catch {
            Darwin.close(descriptor)
            closed = true
            throw error
        }
    }

    deinit {
        if !closed { Darwin.close(descriptor) }
    }

    public func appendCanonicalPCM(
        _ bytes: Data,
        endedAt: Date,
        endedMonotonicNanoseconds: UInt64
    ) throws {
        guard !closed else {
            throw HarcMobileCaptureStorageError.writerClosed
        }
        guard !bytes.isEmpty,
              bytes.count.isMultiple(of: 2),
              endedAt >= lastEndedAt,
              endedMonotonicNanoseconds >= lastEndedMonotonicNanoseconds else {
            throw HarcMobileCaptureStorageError.invalidCanonicalBytes
        }
        let addedFrames = UInt64(bytes.count / 2)
        let newFrames = totalFrames.addingReportingOverflow(addedFrames)
        guard !newFrames.overflow,
              newFrames.partialValue <= UInt64(UInt32.max / 2) else {
            throw HarcMobileCaptureStorageError.invalidCanonicalBytes
        }
        try HarcMobileCaptureFileSystem.writeAll(bytes, to: descriptor)
        hasher.update(data: bytes)
        totalFrames = newFrames.partialValue
        lastEndedAt = endedAt
        lastEndedMonotonicNanoseconds = endedMonotonicNanoseconds
        if totalFrames - durableFrames >= Self.checkpointFrames {
            try checkpoint(force: false)
        }
    }

    public func recordDiscontinuity(
        _ discontinuity: CaptureDiscontinuity
    ) throws {
        guard !closed else {
            throw HarcMobileCaptureStorageError.writerClosed
        }
        guard discontinuity.recordingID == originRecordingID,
              discontinuity.affectedFrames.endFrameExclusive <= totalFrames,
              discontinuities.count < Self.maximumDiscontinuities,
              discontinuities.last.map({
                  ($0.monotonicTimeNanoseconds, $0.wallTime)
                    <= (discontinuity.monotonicTimeNanoseconds, discontinuity.wallTime)
              }) ?? true else {
            throw HarcMobileCaptureStorageError.corruptCheckpoint(
                "discontinuity"
            )
        }
        discontinuities.append(discontinuity)
        try checkpoint(force: true)
    }

    public func checkpointNow() throws {
        try checkpoint(force: true)
    }

    /// Removes a recording that never received a canonical frame. This is the
    /// only in-process discard path; nonempty durable prefixes always remain
    /// recoverable.
    @discardableResult
    public func abandonIfEmpty() throws -> Bool {
        guard !closed else {
            throw HarcMobileCaptureStorageError.writerClosed
        }
        guard totalFrames == 0 else { return false }
        guard Darwin.close(descriptor) == 0 else {
            throw HarcMobileCaptureFileSystem.posix("close", errno)
        }
        closed = true
        for url in [partialURL, checkpointURL]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try HarcMobileCaptureFileSystem.synchronizeDirectory(locations.active)
        return true
    }

    public func finalize(
        reason: HarcMobileCaptureFinalizationReason
    ) throws -> HarcMobileFinalizedMaster {
        guard !closed else {
            throw HarcMobileCaptureStorageError.writerClosed
        }
        guard totalFrames > 0 else {
            throw HarcMobileCaptureStorageError.invalidCanonicalBytes
        }
        try checkpoint(force: true)
        let hash = try CanonicalPCMHash(Data(hasher.finalize()))
        try Self.writeWAVHeader(totalFrames: totalFrames, to: descriptor)
        try HarcMobileCaptureFileSystem.synchronize(descriptor)
        try HarcMobileCaptureFileSystem.validateRegularFile(
            descriptor,
            expectedURL: partialURL
        )
        guard Darwin.close(descriptor) == 0 else {
            throw HarcMobileCaptureFileSystem.posix("close", errno)
        }
        closed = true

        let finalURL = locations.finalizedMasterURL(
            recordingUUID: originRecordingID.recordingUUID
        )
        try HarcMobileCaptureFileSystem.renameExclusive(
            from: partialURL,
            to: finalURL
        )
        try attributes.applyAndVerify(.transferArtifact, to: finalURL)
        let result = HarcMobileFinalizedMaster(
            producingDeviceID: producingDeviceID,
            originRecordingID: originRecordingID,
            masterFileURL: finalURL,
            captureStartedAt: captureStartedAt,
            captureEndedAt: lastEndedAt,
            captureStartedMonotonicNanoseconds:
                captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                lastEndedMonotonicNanoseconds,
            finalizationReason: reason,
            totalCanonicalFrames: totalFrames,
            canonicalPCMSHA256: hash,
            discontinuities: discontinuities
        )
        try Self.persistFinalizedMetadata(
            result,
            locations: locations,
            attributes: attributes
        )
        try FileManager.default.removeItem(at: checkpointURL)
        try HarcMobileCaptureFileSystem.synchronizeDirectory(locations.active)
        return result
    }

    private func checkpoint(force: Bool) throws {
        guard force || totalFrames > durableFrames else { return }
        try HarcMobileCaptureFileSystem.synchronize(descriptor)
        let checkpoint = HarcMobileCaptureCheckpoint(
            version: Self.checkpointVersion,
            producingDeviceID: producingDeviceID,
            originRecordingID: originRecordingID,
            captureStartedAt: captureStartedAt,
            captureStartedMonotonicNanoseconds:
                captureStartedMonotonicNanoseconds,
            durableEndedAt: lastEndedAt,
            durableEndedMonotonicNanoseconds:
                lastEndedMonotonicNanoseconds,
            durableCanonicalFrames: totalFrames,
            discontinuities: discontinuities
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try HarcMobileCaptureFileSystem.atomicWrite(
            encoder.encode(checkpoint),
            to: checkpointURL
        )
        try attributes.applyAndVerify(.transferArtifact, to: checkpointURL)
        try HarcMobileCaptureFileSystem.synchronizeDirectory(locations.active)
        durableFrames = totalFrames
    }

    private static var checkpointVersion: Int {
        HarcMobileCaptureCheckpoint.version
    }

    fileprivate static func persistFinalizedMetadata(
        _ result: HarcMobileFinalizedMaster,
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying
    ) throws {
        let metadataURL = locations.finalized
            .appendingPathComponent(
                "\(result.originRecordingID.recordingUUID.uuidString.lowercased()).capture.json"
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try HarcMobileCaptureFileSystem.atomicWrite(
            encoder.encode(result),
            to: metadataURL
        )
        try attributes.applyAndVerify(.transferArtifact, to: metadataURL)
        try HarcMobileCaptureFileSystem.synchronizeDirectory(locations.finalized)
    }

    fileprivate static func writeWAVHeader(
        totalFrames: UInt64,
        to descriptor: Int32
    ) throws {
        let pcmBytes = totalFrames * 2
        guard pcmBytes <= UInt64(UInt32.max - 36) else {
            throw HarcMobileCaptureStorageError.invalidCanonicalBytes
        }
        var bytes = Data()
        bytes.append(Data("RIFF".utf8))
        bytes.appendLittleEndian(UInt32(pcmBytes + 36))
        bytes.append(Data("WAVEfmt ".utf8))
        bytes.appendLittleEndian(UInt32(16))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(Self.canonicalSampleRate)
        bytes.appendLittleEndian(Self.canonicalSampleRate * 2)
        bytes.appendLittleEndian(UInt16(2))
        bytes.appendLittleEndian(UInt16(16))
        bytes.append(Data("data".utf8))
        bytes.appendLittleEndian(UInt32(pcmBytes))
        precondition(bytes.count == Int(Self.wavHeaderBytes))
        try HarcMobileCaptureFileSystem.pwriteAll(
            bytes,
            to: descriptor,
            offset: 0
        )
    }

    func simulateProcessTerminationForTesting() throws {
        guard !closed else { return }
        guard Darwin.close(descriptor) == 0 else {
            throw HarcMobileCaptureFileSystem.posix("close", errno)
        }
        closed = true
    }
}

public enum HarcMobileCaptureRecovery {
    public static func recoverDurablePrefixes(
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying =
            FoundationHarcMobileCaptureStorageAttributes()
    ) throws -> [HarcMobileFinalizedMaster] {
        try locations.prepare(attributes: attributes)
        let checkpoints = try FileManager.default.contentsOfDirectory(
            at: locations.active,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".capture.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try checkpoints.compactMap {
            try recover(
                checkpointURL: $0,
                locations: locations,
                attributes: attributes
            )
        }
    }

    private static func recover(
        checkpointURL: URL,
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying
    ) throws -> HarcMobileFinalizedMaster? {
        let data = try Data(contentsOf: checkpointURL)
        guard data.count <= 1_048_576 else {
            throw HarcMobileCaptureStorageError.corruptCheckpoint(
                checkpointURL.lastPathComponent
            )
        }
        let checkpoint = try JSONDecoder().decode(
            HarcMobileCaptureCheckpoint.self,
            from: data
        )
        guard checkpoint.version == HarcMobileCaptureCheckpoint.version,
              checkpoint.originRecordingID.deviceID
                == checkpoint.producingDeviceID,
              checkpoint.discontinuities.count <= 4_096 else {
            throw HarcMobileCaptureStorageError.corruptCheckpoint(
                checkpointURL.lastPathComponent
            )
        }
        let partial = locations.partialMasterURL(
            recordingUUID: checkpoint.originRecordingID.recordingUUID
        )
        let final = locations.finalizedMasterURL(
            recordingUUID: checkpoint.originRecordingID.recordingUUID
        )
        if checkpoint.durableCanonicalFrames == 0 {
            if FileManager.default.fileExists(atPath: partial.path) {
                let descriptor = try HarcMobileCaptureFileSystem
                    .openExistingRegularFile(partial, flags: O_RDONLY)
                Darwin.close(descriptor)
                try FileManager.default.removeItem(at: partial)
            }
            try FileManager.default.removeItem(at: checkpointURL)
            try HarcMobileCaptureFileSystem.synchronizeDirectory(
                locations.active
            )
            return nil
        }
        let expectedLength = 44 + checkpoint.durableCanonicalFrames * 2
        if FileManager.default.fileExists(atPath: partial.path) {
            let descriptor = try HarcMobileCaptureFileSystem.openExistingRegularFile(
                partial,
                flags: O_RDWR
            )
            var descriptorOpen = true
            defer { if descriptorOpen { Darwin.close(descriptor) } }
            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_size >= off_t(expectedLength),
                  ftruncate(descriptor, off_t(expectedLength)) == 0 else {
                throw HarcMobileCaptureStorageError.corruptCheckpoint(
                    partial.lastPathComponent
                )
            }
            try HarcMobileDurableMasterWriter.writeWAVHeader(
                totalFrames: checkpoint.durableCanonicalFrames,
                to: descriptor
            )
            try HarcMobileCaptureFileSystem.synchronize(descriptor)
            guard Darwin.close(descriptor) == 0 else {
                throw HarcMobileCaptureFileSystem.posix("close", errno)
            }
            descriptorOpen = false
            try HarcMobileCaptureFileSystem.renameExclusive(
                from: partial,
                to: final
            )
        }
        let hash = try canonicalHash(
            at: final,
            expectedLength: expectedLength
        )
        try attributes.applyAndVerify(.transferArtifact, to: final)
        let recovery = try CaptureDiscontinuity(
            recordingID: checkpoint.originRecordingID,
            monotonicTimeNanoseconds:
                checkpoint.durableEndedMonotonicNanoseconds,
            wallTime: checkpoint.durableEndedAt,
            reason: .recovery,
            affectedFrames: CanonicalFrameRange(
                startFrame: checkpoint.durableCanonicalFrames,
                endFrameExclusive: checkpoint.durableCanonicalFrames
            ),
            canonicalizationPolicy: .annotateGapWithoutInsertedSilence
        )
        let result = HarcMobileFinalizedMaster(
            producingDeviceID: checkpoint.producingDeviceID,
            originRecordingID: checkpoint.originRecordingID,
            masterFileURL: final,
            captureStartedAt: checkpoint.captureStartedAt,
            captureEndedAt: checkpoint.durableEndedAt,
            captureStartedMonotonicNanoseconds:
                checkpoint.captureStartedMonotonicNanoseconds,
            captureEndedMonotonicNanoseconds:
                checkpoint.durableEndedMonotonicNanoseconds,
            finalizationReason: .recoveredDurablePrefix,
            totalCanonicalFrames: checkpoint.durableCanonicalFrames,
            canonicalPCMSHA256: hash,
            discontinuities: checkpoint.discontinuities + [recovery]
        )
        try HarcMobileDurableMasterWriter.persistFinalizedMetadata(
            result,
            locations: locations,
            attributes: attributes
        )
        try FileManager.default.removeItem(at: checkpointURL)
        try HarcMobileCaptureFileSystem.synchronizeDirectory(locations.active)
        return result
    }

    private static func canonicalHash(
        at url: URL,
        expectedLength: UInt64
    ) throws -> CanonicalPCMHash {
        let descriptor = try HarcMobileCaptureFileSystem.openExistingRegularFile(
            url,
            flags: O_RDONLY
        )
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              UInt64(information.st_size) == expectedLength,
              lseek(descriptor, 44, SEEK_SET) == 44 else {
            throw HarcMobileCaptureStorageError.corruptCheckpoint(
                url.lastPathComponent
            )
        }
        var hasher = SHA256()
        var remaining = Int(expectedLength - 44)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, remaining))
        while remaining > 0 {
            let wanted = min(buffer.count, remaining)
            let count = Darwin.read(descriptor, &buffer, wanted)
            if count > 0 {
                hasher.update(data: Data(buffer[0 ..< count]))
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw HarcMobileCaptureFileSystem.posix("read", errno)
            }
        }
        return try CanonicalPCMHash(Data(hasher.finalize()))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
