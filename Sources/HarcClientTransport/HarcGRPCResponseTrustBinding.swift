import CryptoKit
import Foundation
import GRPCCore
import HarcIdentity
import HarcProtocol
import HarcTransfer
import NIOCore
import NIOHTTP2

/// Fail-closed errors for attaching a bootstrap response to the exact TLS
/// connection which carried its HTTP/2 stream.
public enum HarcGRPCResponseTrustBindingError:
    Error, Equatable, Sendable
{
    case missingParentConnectionChannel
    case missingConnectionTrustHandler
    case eventLoopMismatch
    case noAuthenticatedHandshake
    case duplicateAuthenticatedHandshake
    case missingResponseBinding
    case duplicateResponseBinding(count: Int)
    case malformedResponseBinding
    case invalidResponseBindingAuthentication
    case responseTrustBindingMismatch
}

/// One immutable trust result owned by one physical gRPC connection.
///
/// NIOSSL records the result before completing certificate verification. Every
/// child HTTP/2 stream retrieves this exact holder from its parent pipeline, so
/// a replacement connection cannot relabel a response from an older one.
final class HarcGRPCConnectionTrustBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptedTrust: HarcAcceptedServerTrust?

    func record(_ trust: HarcAcceptedServerTrust) throws {
        lock.lock()
        defer { lock.unlock() }
        guard acceptedTrust == nil else {
            throw HarcGRPCResponseTrustBindingError
                .duplicateAuthenticatedHandshake
        }
        acceptedTrust = trust
    }

    func authenticatedTrust() throws -> HarcAcceptedServerTrust {
        lock.lock()
        defer { lock.unlock() }
        guard let acceptedTrust else {
            throw HarcGRPCResponseTrustBindingError
                .noAuthenticatedHandshake
        }
        return acceptedTrust
    }
}

/// A transparent parent-channel marker which makes the connection's accepted
/// trust available to child HTTP/2 stream initializers.
final class HarcGRPCConnectionTrustHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    let binding: HarcGRPCConnectionTrustBinding

    init(binding: HarcGRPCConnectionTrustBinding) {
        self.binding = binding
    }
}

/// Statelessly seals one physical connection's accepted trust into response
/// metadata under an owner-local HMAC key.
///
/// Server-provided values are removed before this codec's envelope is injected
/// into the first response header block. The envelope contains only a nonce,
/// the accepted authority public key, and the exact TLS certificate. Unsealing
/// reparses the certificate and re-verifies its authority-signed transport set,
/// so no mutable per-stream lookup or abandonment cleanup is required.
final class HarcGRPCResponseTrustCodec: @unchecked Sendable {
    static let metadataKey = "x-harc-internal-response-trust-bin"
    static let authenticationCodeBytes = 32
    static let nonceBytes = 32
    static let maximumSealedBindingBytes = fixedPayloadBytes
        + HarcTLSLeafDERParser.maximumCertificateBytes
        + authenticationCodeBytes

    private static let magic = Data("HARCRTB1".utf8)
    private static let certificateLengthBytes = 4
    private static let fixedPayloadBytes = magic.count
        + nonceBytes
        + P256X963PublicKey.byteCount
        + certificateLengthBytes

    private let authenticationKey: SymmetricKey

    init() {
        authenticationKey = SymmetricKey(size: .bits256)
    }

    func seal(_ trust: HarcAcceptedServerTrust) throws -> Data {
        guard trust.hostTrust.hostAuthorityPublicKey.hostAuthorityID
                == trust.hostTrust.hostAuthorityID,
              trust.exactTransportSet == trust.leaf.exactSignedTransportSet,
              trust.leaf.certificateDER.count
                <= HarcTLSLeafDERParser.maximumCertificateBytes,
              let certificateLength = UInt32(
                exactly: trust.leaf.certificateDER.count
              ) else {
            throw HarcGRPCResponseTrustBindingError
                .responseTrustBindingMismatch
        }

        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0 ..< Self.nonceBytes).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })

        var payload = Self.magic
        payload.append(nonce)
        payload.append(trust.hostTrust.hostAuthorityPublicKey.rawBytes)
        Self.appendBigEndian(certificateLength, to: &payload)
        payload.append(trust.leaf.certificateDER)

        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: authenticationKey
        )
        payload.append(contentsOf: authenticationCode)
        return payload
    }

    func trust(from metadata: Metadata) throws -> HarcAcceptedServerTrust {
        let sealed = try Self.sealedBinding(from: metadata)
        guard sealed.count >= Self.fixedPayloadBytes
                + Self.authenticationCodeBytes,
              sealed.count <= Self.maximumSealedBindingBytes else {
            throw HarcGRPCResponseTrustBindingError.malformedResponseBinding
        }

        let payload = Data(
            sealed.dropLast(Self.authenticationCodeBytes)
        )
        let suppliedAuthenticationCode = Data(
            sealed.suffix(Self.authenticationCodeBytes)
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            suppliedAuthenticationCode,
            authenticating: payload,
            using: authenticationKey
        ) else {
            throw HarcGRPCResponseTrustBindingError
                .invalidResponseBindingAuthentication
        }

        return try Self.reconstructTrust(from: payload)
    }

    private static func sealedBinding(
        from metadata: Metadata
    ) throws -> Data {
        let values = Array(metadata[metadataKey])
        guard !values.isEmpty else {
            throw HarcGRPCResponseTrustBindingError.missingResponseBinding
        }
        guard values.count == 1 else {
            throw HarcGRPCResponseTrustBindingError
                .duplicateResponseBinding(count: values.count)
        }
        guard case .binary(let bytes) = values[0] else {
            throw HarcGRPCResponseTrustBindingError.malformedResponseBinding
        }
        return Data(bytes)
    }

    private static func reconstructTrust(
        from payload: Data
    ) throws -> HarcAcceptedServerTrust {
        let bytes = [UInt8](payload)
        guard bytes.count >= fixedPayloadBytes,
              Data(bytes[0 ..< magic.count]) == magic else {
            throw HarcGRPCResponseTrustBindingError.malformedResponseBinding
        }

        var offset = magic.count
        offset += nonceBytes
        let authorityKeyBytes = Data(
            bytes[offset ..< offset + P256X963PublicKey.byteCount]
        )
        offset += P256X963PublicKey.byteCount
        let certificateLength = bytes[offset ..< offset + certificateLengthBytes]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += certificateLengthBytes

        guard certificateLength > 0,
              certificateLength
                <= UInt32(HarcTLSLeafDERParser.maximumCertificateBytes),
              bytes.count == offset + Int(certificateLength) else {
            throw HarcGRPCResponseTrustBindingError.malformedResponseBinding
        }

        do {
            let authorityPublicKey = try P256X963PublicKey(authorityKeyBytes)
            let leaf = try HarcTLSLeafDERParser.parse(
                Data(bytes[offset ..< bytes.count])
            )
            let verifiedSet = try VerifiedHostTransportSetV1.decode(
                leaf.exactSignedTransportSet,
                hostAuthorityPublicKey: authorityPublicKey
            )
            guard verifiedSet.exactSignedBytes
                    == leaf.exactSignedTransportSet,
                  verifiedSet.transportSet.hostAuthorityID
                    == authorityPublicKey.hostAuthorityID,
                  let coveringEntry = verifiedSet.transportSet.entries.first(
                    where: {
                        $0.tlsSPKISHA256 == leaf.fullDERSPKISHA256
                    }
                  ),
                  let certificateNotBefore = unixMilliseconds(
                    leaf.notValidBefore
                  ),
                  let certificateNotAfter = unixMilliseconds(
                    leaf.notValidAfter
                  ),
                  certificateNotBefore
                    >= coveringEntry.notBeforeUnixMilliseconds,
                  certificateNotAfter
                    <= coveringEntry.notAfterUnixMilliseconds else {
                throw HarcGRPCResponseTrustBindingError
                    .responseTrustBindingMismatch
            }

            let hostTrust = try RecordingHostTrustBinding(
                libraryID: verifiedSet.transportSet.libraryID,
                hostAuthorityID: verifiedSet.transportSet.hostAuthorityID,
                hostAuthorityPublicKey: authorityPublicKey
            )
            return HarcAcceptedServerTrust(
                hostTrust: hostTrust,
                transportSetEpoch: verifiedSet.transportSet.setEpoch,
                exactTransportSet: verifiedSet.exactSignedBytes,
                leaf: leaf
            )
        } catch let error as HarcGRPCResponseTrustBindingError {
            throw error
        } catch {
            throw HarcGRPCResponseTrustBindingError
                .responseTrustBindingMismatch
        }
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    private static func unixMilliseconds(_ date: Date) -> UInt64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= 0,
              seconds.rounded(.towardZero) == seconds,
              seconds <= Double(UInt64.max / 1_000) else {
            return nil
        }
        return UInt64(seconds) * 1_000
    }
}

/// Installs the response-binding handler ahead of gRPC's stream handler. The
/// parent channel is the authoritative association between this stream and its
/// accepted TLS leaf; no global or "latest handshake" state participates.
enum HarcGRPCResponseTrustBridge {
    static func initializeStream(
        channel: any Channel,
        codec: HarcGRPCResponseTrustCodec
    ) -> EventLoopFuture<Void> {
        guard let connectionChannel = channel.parent else {
            return channel.eventLoop.makeFailedFuture(
                HarcGRPCResponseTrustBindingError
                    .missingParentConnectionChannel
            )
        }

        return channel.eventLoop.makeCompletedFuture {
            guard channel.eventLoop.inEventLoop,
                  connectionChannel.eventLoop.inEventLoop else {
                throw HarcGRPCResponseTrustBindingError.eventLoopMismatch
            }

            let holder: HarcGRPCConnectionTrustHandler
            do {
                holder = try connectionChannel.pipeline.syncOperations
                    .handler(type: HarcGRPCConnectionTrustHandler.self)
            } catch {
                throw HarcGRPCResponseTrustBindingError
                    .missingConnectionTrustHandler
            }

            let trust = try holder.binding.authenticatedTrust()
            try channel.pipeline.syncOperations.addHandler(
                HarcGRPCResponseTrustMetadataHandler(
                    trust: trust,
                    codec: codec
                ),
                position: .first
            )
        }
    }
}

/// Removes all peer-controlled values for the reserved response-binding key,
/// injects exactly one client-owned value on initial headers, and scrubs it
/// from trailers. The envelope is sealed only after a response arrives.
final class HarcGRPCResponseTrustMetadataHandler:
    ChannelInboundHandler, RemovableChannelHandler
{
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload

    private let trust: HarcAcceptedServerTrust
    private let codec: HarcGRPCResponseTrustCodec
    private var receivedInitialHeaders = false

    init(
        trust: HarcAcceptedServerTrust,
        codec: HarcGRPCResponseTrustCodec
    ) {
        self.trust = trust
        self.codec = codec
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .headers(var headers) = payload else {
            context.fireChannelRead(data)
            return
        }

        headers.headers.remove(
            name: HarcGRPCResponseTrustCodec.metadataKey
        )
        if !receivedInitialHeaders {
            receivedInitialHeaders = true
            guard !headers.endStream else {
                context.fireChannelRead(wrapInboundOut(.headers(headers)))
                return
            }
            let sealedTrust: Data
            do {
                sealedTrust = try codec.seal(trust)
            } catch {
                context.fireErrorCaught(error)
                context.close(promise: nil)
                return
            }
            headers.headers.add(
                name: HarcGRPCResponseTrustCodec.metadataKey,
                value: sealedTrust.base64EncodedString(),
                indexing: .neverIndexed
            )
        }
        context.fireChannelRead(wrapInboundOut(.headers(headers)))
    }
}
