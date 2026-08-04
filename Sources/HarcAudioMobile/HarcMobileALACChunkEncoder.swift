import CryptoKit
import Darwin
import Foundation
import HarcDomain
@preconcurrency import AVFoundation

public struct HarcMobileEncodedChunkArtifact: Equatable, Sendable {
    public let chunkIndex: UInt32
    public let canonicalStartFrame: UInt64
    public let canonicalFrameCount: UInt64
    public let encodedFileURL: URL
    public let encodedByteLength: UInt64
    public let encodedSHA256: Data
    public let canonicalDecodedByteLength: UInt64
    public let canonicalDecodedSHA256: Data
}

public enum HarcMobileALACEncodingError: Error, Equatable, Sendable {
    case invalidMaster
    case tooManyChunks
    case encodedChunkTooLarge
    case encodingFailed(chunkIndex: UInt32)
    case decodingFailed(chunkIndex: UInt32)
    case decodeMismatch(chunkIndex: UInt32)
}

/// CAF+ALAC candidate for the required physical-iPhone codec qualification
/// matrix. Production composition must not select it until that gate freezes
/// the release codec. Every produced candidate artifact is independently
/// decoded and proved bit-exact before publication.
public struct HarcMobileALACChunkEncoder: Sendable {
    public static let framesPerChunk: UInt64 = 60 * 16_000
    public static let maximumChunks = 4_096
    public static let maximumEncodedBytes: UInt64 = 4 * 1_024 * 1_024

    public init() {}

    public func encode(
        _ master: HarcMobileFinalizedMaster,
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying =
            FoundationHarcMobileCaptureStorageAttributes()
    ) throws -> [HarcMobileEncodedChunkArtifact] {
        try locations.prepare(attributes: attributes)
        let descriptor = try HarcMobileCaptureFileSystem.openExistingRegularFile(
            master.masterFileURL,
            flags: O_RDONLY
        )
        defer { Darwin.close(descriptor) }
        try validateMaster(master, descriptor: descriptor)

        let chunkCount = Int(
            (master.totalCanonicalFrames + Self.framesPerChunk - 1)
                / Self.framesPerChunk
        )
        guard chunkCount > 0, chunkCount <= Self.maximumChunks else {
            throw HarcMobileALACEncodingError.tooManyChunks
        }
        var artifacts: [HarcMobileEncodedChunkArtifact] = []
        artifacts.reserveCapacity(chunkCount)
        for index in 0..<chunkCount {
            let start = UInt64(index) * Self.framesPerChunk
            let frames = min(
                Self.framesPerChunk,
                master.totalCanonicalFrames - start
            )
            let canonical = try HarcMobileCaptureFileSystem.preadExact(
                count: Int(frames * 2),
                from: descriptor,
                offset: off_t(44 + start * 2)
            )
            artifacts.append(try encodeChunk(
                canonical,
                master: master,
                chunkIndex: UInt32(index),
                startFrame: start,
                frameCount: frames,
                locations: locations,
                attributes: attributes
            ))
        }
        return artifacts
    }

    private func encodeChunk(
        _ canonical: Data,
        master: HarcMobileFinalizedMaster,
        chunkIndex: UInt32,
        startFrame: UInt64,
        frameCount: UInt64,
        locations: HarcMobileCaptureLocations,
        attributes: any HarcMobileCaptureStorageAttributeApplying
    ) throws -> HarcMobileEncodedChunkArtifact {
        let destination = locations.encodedChunkURL(
            recordingUUID: master.originRecordingID.recordingUUID,
            chunkIndex: chunkIndex
        )
        let canonicalHash = Data(SHA256.hash(data: canonical))
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = locations.encoded.appendingPathComponent(
                ".\(destination.deletingPathExtension().lastPathComponent)"
                    + ".\(UUID().uuidString.lowercased()).partial.caf"
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try writeALAC(canonical, to: temporary)
            } catch {
                throw HarcMobileALACEncodingError.encodingFailed(
                    chunkIndex: chunkIndex
                )
            }
            let temporaryDescriptor = try HarcMobileCaptureFileSystem
                .openExistingRegularFile(temporary, flags: O_RDONLY)
            defer { Darwin.close(temporaryDescriptor) }
            try HarcMobileCaptureFileSystem.synchronize(temporaryDescriptor)
            let temporarySize = try HarcMobileCaptureFileSystem.fileSize(
                temporaryDescriptor
            )
            guard temporarySize > 0,
                  UInt64(temporarySize) <= Self.maximumEncodedBytes else {
                throw HarcMobileALACEncodingError.encodedChunkTooLarge
            }
            do {
                try verifyDecoded(
                    temporary,
                    expectedBytes: canonical.count,
                    expectedSHA256: canonicalHash,
                    chunkIndex: chunkIndex
                )
            } catch let error as HarcMobileALACEncodingError {
                throw error
            } catch {
                throw HarcMobileALACEncodingError.decodingFailed(
                    chunkIndex: chunkIndex
                )
            }
            try attributes.applyAndVerify(.transferArtifact, to: temporary)
            try HarcMobileCaptureFileSystem.renameExclusive(
                from: temporary,
                to: destination
            )
        }
        try attributes.applyAndVerify(.transferArtifact, to: destination)
        do {
            try verifyDecoded(
                destination,
                expectedBytes: canonical.count,
                expectedSHA256: canonicalHash,
                chunkIndex: chunkIndex
            )
        } catch let error as HarcMobileALACEncodingError {
            throw error
        } catch {
            throw HarcMobileALACEncodingError.decodingFailed(
                chunkIndex: chunkIndex
            )
        }
        let encoded = try Data(contentsOf: destination, options: .mappedIfSafe)
        guard !encoded.isEmpty,
              UInt64(encoded.count) <= Self.maximumEncodedBytes else {
            throw HarcMobileALACEncodingError.encodedChunkTooLarge
        }
        return HarcMobileEncodedChunkArtifact(
            chunkIndex: chunkIndex,
            canonicalStartFrame: startFrame,
            canonicalFrameCount: frameCount,
            encodedFileURL: destination,
            encodedByteLength: UInt64(encoded.count),
            encodedSHA256: Data(SHA256.hash(data: encoded)),
            canonicalDecodedByteLength: UInt64(canonical.count),
            canonicalDecodedSHA256: canonicalHash
        )
    }

    private func writeALAC(_ canonical: Data, to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let frames = AVAudioFrameCount(canonical.count / 2)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames
        ) else {
            throw HarcMobileALACEncodingError.invalidMaster
        }
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard list.count == 1, let destination = list[0].mData else {
            throw HarcMobileALACEncodingError.invalidMaster
        }
        canonical.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: canonical.count
        )
        list[0].mDataByteSize = UInt32(canonical.count)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }

    private func verifyDecoded(
        _ url: URL,
        expectedBytes: Int,
        expectedSHA256: Data,
        chunkIndex: UInt32
    ) throws {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1 else {
            throw HarcMobileALACEncodingError.decodeMismatch(
                chunkIndex: chunkIndex
            )
        }
        var hasher = SHA256()
        var byteCount = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(remaining, 65_536))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frames
            ) else {
                throw HarcMobileALACEncodingError.decodeMismatch(
                    chunkIndex: chunkIndex
                )
            }
            try file.read(into: buffer, frameCount: frames)
            let list = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            )
            guard list.count == 1, let bytes = list[0].mData else {
                throw HarcMobileALACEncodingError.decodeMismatch(
                    chunkIndex: chunkIndex
                )
            }
            let data = Data(bytes: bytes, count: Int(list[0].mDataByteSize))
            hasher.update(data: data)
            byteCount += data.count
        }
        guard byteCount == expectedBytes,
              Data(hasher.finalize()) == expectedSHA256 else {
            throw HarcMobileALACEncodingError.decodeMismatch(
                chunkIndex: chunkIndex
            )
        }
    }

    private func validateMaster(
        _ master: HarcMobileFinalizedMaster,
        descriptor: Int32
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size == off_t(44 + master.totalCanonicalBytes) else {
            throw HarcMobileALACEncodingError.invalidMaster
        }
        let header = try HarcMobileCaptureFileSystem.preadExact(
            count: 44,
            from: descriptor,
            offset: 0
        )
        guard header.prefix(4) == Data("RIFF".utf8),
              UInt64(header.littleEndianUInt32(at: 4)) + 8
                == UInt64(44) + master.totalCanonicalBytes,
              header[8..<12] == Data("WAVE".utf8),
              header[12..<16] == Data("fmt ".utf8),
              header.littleEndianUInt32(at: 16) == 16,
              header[36..<40] == Data("data".utf8),
              header.littleEndianUInt16(at: 20) == 1,
              header.littleEndianUInt16(at: 22) == 1,
              header.littleEndianUInt32(at: 24) == 16_000,
              header.littleEndianUInt32(at: 28) == 32_000,
              header.littleEndianUInt16(at: 32) == 2,
              header.littleEndianUInt16(at: 34) == 16,
              UInt64(header.littleEndianUInt32(at: 40))
                == master.totalCanonicalBytes else {
            throw HarcMobileALACEncodingError.invalidMaster
        }
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { raw in
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
