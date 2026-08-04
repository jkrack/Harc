@preconcurrency import AVFoundation
import Darwin
import Foundation
import HarcTransfer

/// One already-durable staged object and the immutable declaration that must
/// describe both its encoded bytes and the canonical PCM emitted by a decoder.
/// This is an internal application-service value; transport DTOs never carry a
/// host path.
public struct HostChunkDecodeRequest: Sendable {
    /// A fresh, independently positioned descriptor-relative read handle.
    /// HarcHost owns and closes it immediately after `decode` returns. Decoder
    /// implementations must neither close it nor retain it beyond that call.
    public let stagedEncodedHandle: HostStagedObjectReadHandle
    public let descriptor: LogicalChunkDescriptor
    public let uploadPurpose: UploadProfilePurpose

    public init(
        stagedEncodedHandle: HostStagedObjectReadHandle,
        descriptor: LogicalChunkDescriptor,
        uploadPurpose: UploadProfilePurpose
    ) {
        self.stagedEncodedHandle = stagedEncodedHandle
        self.descriptor = descriptor
        self.uploadPurpose = uploadPurpose
    }
}

/// Bounded streaming decoder boundary. Implementations must emit canonical
/// mono signed Int16 little-endian bytes in order and must not allocate from a
/// peer-declared total. HarcHost independently checks the emitted length and
/// SHA-256 before publication.
public protocol HostChunkDecoding: Sendable {
    func decode(
        _ request: HostChunkDecodeRequest,
        emitCanonicalPCM: @escaping @Sendable (Data) async throws -> Void
    ) async throws
}

/// Shipping default while the physical-device codec qualification gate is
/// open. Merely naming a codec in a negotiated profile never enables decode.
public struct QualifiedHostChunkDecoderUnavailable: HostChunkDecoding {
    public init() {}

    public func decode(
        _ request: HostChunkDecodeRequest,
        emitCanonicalPCM: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        throw HarcHostError.qualifiedDecoderUnavailable(
            codec: request.descriptor.encoding.codec.rawValue,
            container: request.descriptor.encoding.container.rawValue
        )
    }
}

/// Production CAF/ALAC decoder for Harc V1 chunks.
///
/// The peer never supplies a filesystem path. The already-validated staging
/// descriptor is copied into a private, exclusively-created temporary object,
/// which AVFoundation opens only for the duration of this call. The decoded
/// stream remains bounded by both the signed frame declaration and Harc's
/// fixed-size output fragments.
public struct CAFALACHostChunkDecoder: HostChunkDecoding {
    public static let maximumDecodedFramesPerFragment: AVAudioFrameCount = 32_768

    public init() {}

    public func decode(
        _ request: HostChunkDecodeRequest,
        emitCanonicalPCM: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard request.descriptor.encoding == .cafALAC else {
            throw HarcHostError.qualifiedDecoderUnavailable(
                codec: request.descriptor.encoding.codec.rawValue,
                container: request.descriptor.encoding.container.rawValue
            )
        }

        let temporaryURL = try materializeEncodedObject(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: temporaryURL,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw HarcHostError.publicationIO(
                "Could not open the staged CAF/ALAC object: \(error.localizedDescription)"
            )
        }

        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatInt16,
              format.isInterleaved,
              format.channelCount == UInt32(request.descriptor.canonicalFormat.channelCount),
              format.sampleRate == Double(request.descriptor.canonicalFormat.sampleRateHz)
        else {
            throw HarcHostError.publicationIO(
                "The decoded CAF/ALAC stream does not match Harc canonical PCM V1."
            )
        }
        guard file.length >= 0,
              UInt64(file.length) == request.descriptor.canonicalFrameCount
        else {
            throw HarcHostError.decodedLengthMismatch(
                expected: request.descriptor.canonicalDecodedByteLength,
                actual: file.length > 0 ? UInt64(file.length) * 2 : 0
            )
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: Self.maximumDecodedFramesPerFragment
        ) else {
            throw HarcHostError.publicationIO(
                "Could not allocate the bounded CAF/ALAC decode buffer."
            )
        }

        var emittedFrames: UInt64 = 0
        while emittedFrames < request.descriptor.canonicalFrameCount {
            let remaining = request.descriptor.canonicalFrameCount - emittedFrames
            let requestedFrames = AVAudioFrameCount(
                min(UInt64(Self.maximumDecodedFramesPerFragment), remaining)
            )
            do {
                try file.read(into: buffer, frameCount: requestedFrames)
            } catch {
                throw HarcHostError.publicationIO(
                    "Could not decode the staged CAF/ALAC object: \(error.localizedDescription)"
                )
            }
            guard buffer.frameLength > 0,
                  buffer.frameLength <= requestedFrames,
                  let audioBuffer = buffer.audioBufferList.pointee.mBuffers.mData
            else {
                throw HarcHostError.incompleteBody
            }

            let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
            try await emitCanonicalPCM(Data(bytes: audioBuffer, count: byteCount))
            emittedFrames += UInt64(buffer.frameLength)
        }

        guard emittedFrames == request.descriptor.canonicalFrameCount else {
            throw HarcHostError.decodedLengthMismatch(
                expected: request.descriptor.canonicalDecodedByteLength,
                actual: emittedFrames * 2
            )
        }
    }

    private func materializeEncodedObject(
        _ request: HostChunkDecodeRequest
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let template = directory
            .appendingPathComponent("harc-host-alac-XXXXXX.caf")
            .path
        var templateBytes = Array(template.utf8CString)
        let descriptor = templateBytes.withUnsafeMutableBufferPointer { buffer in
            mkstemps(buffer.baseAddress, 4)
        }
        guard descriptor >= 0 else {
            throw HarcHostError.publicationIO(
                "Could not create a private CAF/ALAC decode object: errno \(errno)."
            )
        }
        let path = String(
            decoding: templateBytes.dropLast().map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let url = URL(fileURLWithPath: path)
        var shouldRemove = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: url) }
        }

        var remaining = request.descriptor.encodedByteLength
        while remaining > 0 {
            let requested = Int(min(
                remaining,
                UInt64(HostStagedObjectReadHandle.maximumReadBytes)
            ))
            let fragment = try request.stagedEncodedHandle.read(upToCount: requested)
            guard !fragment.isEmpty else { throw HarcHostError.incompleteBody }
            try writeAll(fragment, to: descriptor)
            remaining -= UInt64(fragment.count)
        }
        guard try request.stagedEncodedHandle.read(upToCount: 1).isEmpty else {
            let actual = request.descriptor.encodedByteLength.addingReportingOverflow(1)
            throw HarcHostError.encodedLengthMismatch(
                expected: request.descriptor.encodedByteLength,
                actual: actual.overflow ? .max : actual.partialValue
            )
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HarcHostError.publicationIO(
                "Could not synchronize the private CAF/ALAC decode object: errno \(errno)."
            )
        }
        shouldRemove = false
        return url
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw HarcHostError.publicationIO(
                        "Could not write the private CAF/ALAC decode object: errno \(errno)."
                    )
                }
                offset += written
            }
        }
    }
}

/// Non-shipping fixture decoder. It is internal so production composition
/// cannot accidentally opt raw PCM into the release path; `@testable` host
/// tests may inject it for deterministic ingest and crash-recovery coverage.
struct RawPCMFixtureHostChunkDecoder: HostChunkDecoding {
    static let fragmentBytes = 256 * 1_024

    func decode(
        _ request: HostChunkDecodeRequest,
        emitCanonicalPCM: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard request.uploadPurpose == .fixtureLoopback,
              request.descriptor.encoding == .rawPCMFixture
        else {
            throw HarcHostError.fixtureDecoderForbidden
        }

        var remaining = request.descriptor.encodedByteLength
        while remaining > 0 {
            let requested = Int(min(remaining, UInt64(Self.fragmentBytes)))
            let fragment = try request.stagedEncodedHandle.read(upToCount: requested)
            guard !fragment.isEmpty else { throw HarcHostError.incompleteBody }
            remaining -= UInt64(fragment.count)
            try await emitCanonicalPCM(fragment)
        }
        guard try request.stagedEncodedHandle.read(upToCount: 1).isEmpty else {
            let onePastExpected = request.descriptor.encodedByteLength
                .addingReportingOverflow(1)
            throw HarcHostError.encodedLengthMismatch(
                expected: request.descriptor.encodedByteLength,
                actual: onePastExpected.overflow ? .max : onePastExpected.partialValue
            )
        }
    }
}
