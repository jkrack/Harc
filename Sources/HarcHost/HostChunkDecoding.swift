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
