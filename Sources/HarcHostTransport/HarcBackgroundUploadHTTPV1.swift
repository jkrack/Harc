#if canImport(Network)
import Foundation
import HarcDomain
import HarcTransfer
import NIOCore
import NIOHTTP1

public enum HarcBackgroundUploadHTTPV1Error: Error, Equatable, Sendable {
    case unsupportedHTTPVersion
    case methodNotAllowed
    case routeNotFound
    case invalidAuthorization
    case invalidContentType
    case invalidContentLength
    case bodyTooLarge
    case unsupportedTransferEncoding
    case unsupportedContentEncoding
    case unsupportedTrailer
    case invalidExpectHeader
    case invalidHostHeader
    case acknowledgementTooLarge
}

public struct HarcBackgroundUploadHTTPRequestHeadV1: Equatable, Sendable {
    public let uploadID: UploadID
    public let batchID: AudioBatchID
    public let exactPath: String
    public let opaqueCapabilityCredential: Data
    public let contentLength: UInt64
    public let expectsContinue: Bool

    public init(
        uploadID: UploadID,
        batchID: AudioBatchID,
        exactPath: String,
        opaqueCapabilityCredential: Data,
        contentLength: UInt64,
        expectsContinue: Bool
    ) {
        self.uploadID = uploadID
        self.batchID = batchID
        self.exactPath = exactPath
        self.opaqueCapabilityCredential = opaqueCapabilityCredential
        self.contentLength = contentLength
        self.expectsContinue = expectsContinue
    }
}

/// Strict framing and routing for the single background-upload HTTP surface.
/// This layer deliberately performs no authority decision: the credential and
/// exact request facts are handed to HarcHost for constant-time admission.
public enum HarcBackgroundUploadHTTPV1 {
    public static let requestContentType =
        "application/vnd.harc.audio-batch.v1"
    public static let acknowledgementContentType =
        "application/vnd.harc.batch-ack.v1"
    public static let maximumBodyBytes: UInt64 = 64 * 1_024 * 1_024
    public static let maximumAcknowledgementBytes = 1 * 1_024 * 1_024

    private static let authorizationScheme = "HarcUpload "
    private static let encodedCredentialLength = 64
    private static let credentialLength = 48

    public static func parseRequestHead(
        _ head: HTTPRequestHead
    ) throws -> HarcBackgroundUploadHTTPRequestHeadV1 {
        guard head.version == .http1_1 else {
            throw HarcBackgroundUploadHTTPV1Error.unsupportedHTTPVersion
        }
        guard head.method == .PUT else {
            throw HarcBackgroundUploadHTTPV1Error.methodNotAllowed
        }

        let (uploadID, batchID) = try parseRoute(head.uri)
        let credential = try parseAuthorization(head.headers)
        let contentLength = try parseContentLength(head.headers)

        guard exactHeaderValues("content-type", in: head.headers)
                == [requestContentType] else {
            throw HarcBackgroundUploadHTTPV1Error.invalidContentType
        }
        guard exactHeaderValues("transfer-encoding", in: head.headers).isEmpty
        else {
            throw HarcBackgroundUploadHTTPV1Error
                .unsupportedTransferEncoding
        }
        guard exactHeaderValues("content-encoding", in: head.headers).isEmpty
        else {
            throw HarcBackgroundUploadHTTPV1Error
                .unsupportedContentEncoding
        }
        guard exactHeaderValues("trailer", in: head.headers).isEmpty else {
            throw HarcBackgroundUploadHTTPV1Error.unsupportedTrailer
        }

        let expectValues = exactHeaderValues("expect", in: head.headers)
        let expectsContinue: Bool
        if expectValues.isEmpty {
            expectsContinue = false
        } else if expectValues.count == 1,
                  expectValues[0].lowercased() == "100-continue" {
            expectsContinue = true
        } else {
            throw HarcBackgroundUploadHTTPV1Error.invalidExpectHeader
        }

        let hostValues = exactHeaderValues("host", in: head.headers)
        guard hostValues.count == 1,
              isSafeHostHeaderValue(hostValues[0]) else {
            throw HarcBackgroundUploadHTTPV1Error.invalidHostHeader
        }

        return HarcBackgroundUploadHTTPRequestHeadV1(
            uploadID: uploadID,
            batchID: batchID,
            exactPath: head.uri,
            opaqueCapabilityCredential: credential,
            contentLength: contentLength,
            expectsContinue: expectsContinue
        )
    }

    public static func makeContinueResponseHead() -> HTTPResponseHead {
        HTTPResponseHead(version: .http1_1, status: .continue)
    }

    public static func makeSuccessResponse(
        exactAcknowledgementBytes: Data
    ) throws -> (head: HTTPResponseHead, body: ByteBuffer) {
        guard !exactAcknowledgementBytes.isEmpty,
              exactAcknowledgementBytes.count <= maximumAcknowledgementBytes
        else {
            throw HarcBackgroundUploadHTTPV1Error.acknowledgementTooLarge
        }
        var headers = responseHeaders(
            contentLength: exactAcknowledgementBytes.count,
            contentType: acknowledgementContentType
        )
        headers.add(name: "Cache-Control", value: "no-store")
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: headers
        )
        return (head, ByteBuffer(bytes: exactAcknowledgementBytes))
    }

    /// All errors are empty, connection-closing responses. The accepted status
    /// set intentionally excludes every redirect code.
    public static func makeErrorResponseHead(
        status: HTTPResponseStatus
    ) -> HTTPResponseHead {
        precondition(
            status.code >= 400 && status.code <= 599,
            "The background upload edge must never construct a redirect."
        )
        return HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: responseHeaders(contentLength: 0, contentType: nil)
        )
    }

    public static func responseStatus(
        for error: HarcBackgroundUploadHTTPV1Error
    ) -> HTTPResponseStatus {
        switch error {
        case .unsupportedHTTPVersion:
            return .httpVersionNotSupported
        case .methodNotAllowed:
            return .methodNotAllowed
        case .routeNotFound:
            return .notFound
        case .invalidAuthorization:
            return .unauthorized
        case .invalidContentType, .unsupportedContentEncoding:
            return .unsupportedMediaType
        case .invalidContentLength, .unsupportedTransferEncoding,
             .unsupportedTrailer, .invalidHostHeader:
            return .badRequest
        case .bodyTooLarge:
            return .payloadTooLarge
        case .invalidExpectHeader:
            return .expectationFailed
        case .acknowledgementTooLarge:
            return .internalServerError
        }
    }

    private static func parseRoute(
        _ uri: String
    ) throws -> (UploadID, AudioBatchID) {
        guard !uri.isEmpty,
              !uri.contains("%"),
              !uri.contains("?"),
              !uri.contains("#"),
              !uri.utf8.contains(where: { $0 < 0x21 || $0 > 0x7e }) else {
            throw HarcBackgroundUploadHTTPV1Error.routeNotFound
        }
        let components = uri.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 6,
              components[0].isEmpty,
              components[1] == "v1",
              components[2] == "uploads",
              components[4] == "batches",
              !components[3].isEmpty,
              !components[5].isEmpty,
              let uploadUUID = UUID(uuidString: String(components[3])),
              let batchUUID = UUID(uuidString: String(components[5])),
              String(components[3]) == uploadUUID.uuidString.lowercased(),
              String(components[5]) == batchUUID.uuidString.lowercased() else {
            throw HarcBackgroundUploadHTTPV1Error.routeNotFound
        }
        return (UploadID(uploadUUID), AudioBatchID(batchUUID))
    }

    private static func parseAuthorization(
        _ headers: HTTPHeaders
    ) throws -> Data {
        let values = exactHeaderValues("authorization", in: headers)
        guard values.count == 1,
              values[0].hasPrefix(authorizationScheme) else {
            throw HarcBackgroundUploadHTTPV1Error.invalidAuthorization
        }
        let encoded = String(values[0].dropFirst(authorizationScheme.count))
        guard encoded.utf8.count == encodedCredentialLength,
              encoded.utf8.allSatisfy(isBase64URLCharacter),
              let credential = decodeBase64URL(encoded),
              credential.count == credentialLength,
              encodeBase64URL(credential) == encoded else {
            throw HarcBackgroundUploadHTTPV1Error.invalidAuthorization
        }
        return credential
    }

    private static func parseContentLength(
        _ headers: HTTPHeaders
    ) throws -> UInt64 {
        let values = exactHeaderValues("content-length", in: headers)
        guard values.count == 1 else {
            throw HarcBackgroundUploadHTTPV1Error.invalidContentLength
        }
        let value = values[0]
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              value == "0" || value.first != "0",
              let length = UInt64(value),
              length > 0 else {
            throw HarcBackgroundUploadHTTPV1Error.invalidContentLength
        }
        guard length <= maximumBodyBytes else {
            throw HarcBackgroundUploadHTTPV1Error.bodyTooLarge
        }
        return length
    }

    private static func exactHeaderValues(
        _ name: String,
        in headers: HTTPHeaders
    ) -> [String] {
        headers.compactMap { header in
            header.name.lowercased() == name ? header.value : nil
        }
    }

    private static func isSafeHostHeaderValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                byte >= 0x21 && byte <= 0x7e && byte != 0x2c
            }
    }

    private static func isBase64URLCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2d
            || byte == 0x5f
    }

    private static func decodeBase64URL(_ encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(
            String(repeating: "=", count: (4 - base64.count % 4) % 4)
        )
        return Data(base64Encoded: base64)
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func responseHeaders(
        contentLength: Int,
        contentType: String?
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(contentLength))
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        return headers
    }
}
#endif
