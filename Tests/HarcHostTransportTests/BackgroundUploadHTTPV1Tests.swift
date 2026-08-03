#if canImport(Network)
import Foundation
import HarcHostTransport
import NIOHTTP1
import Testing

@Suite("Background upload HTTP/1.1 edge")
struct BackgroundUploadHTTPV1Tests {
    @Test("the one canonical PUT route yields exact bounded request facts")
    func canonicalRequest() throws {
        let credential = Data((0..<48).map(UInt8.init))
        let request = try HarcBackgroundUploadHTTPV1.parseRequestHead(
            makeHead(credential: credential)
        )

        #expect(request.uploadID.description == uploadID)
        #expect(request.batchID.description == batchID)
        #expect(request.exactPath == path)
        #expect(request.opaqueCapabilityCredential == credential)
        #expect(request.contentLength == 4_096)
        #expect(!request.expectsContinue)
    }

    @Test("routing method and HTTP version fail before application admission")
    func routeMethodAndVersion() throws {
        let credential = Data(repeating: 0xA1, count: 48)
        var wrongMethod = makeHead(credential: credential)
        wrongMethod.method = .POST
        #expect(throws: HarcBackgroundUploadHTTPV1Error.methodNotAllowed) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(wrongMethod)
        }

        for badPath in [
            path + "?retry=1",
            path.replacingOccurrences(of: uploadID, with: uploadID.uppercased()),
            path + "/",
            "/v1/uploads/%2e%2e/batches/" + batchID,
        ] {
            var head = makeHead(credential: credential)
            head.uri = badPath
            #expect(throws: HarcBackgroundUploadHTTPV1Error.routeNotFound) {
                try HarcBackgroundUploadHTTPV1.parseRequestHead(head)
            }
        }

        var http10 = makeHead(credential: credential)
        http10.version = .http1_0
        #expect(
            throws: HarcBackgroundUploadHTTPV1Error.unsupportedHTTPVersion
        ) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(http10)
        }
    }

    @Test("credential framing is exact canonical base64url")
    func authorization() throws {
        let credential = Data(repeating: 0xFB, count: 48)
        let canonical = encodeBase64URL(credential)
        #expect(canonical.count == 64)

        for value in [
            canonical,
            "HarcUpload " + canonical + "=",
            "harcupload " + canonical,
            "HarcUpload " + String(canonical.dropLast()),
            "HarcUpload " + canonical.replacingOccurrences(of: "-", with: "+"),
        ] {
            var head = makeHead(credential: credential)
            head.headers.remove(name: "Authorization")
            head.headers.add(name: "Authorization", value: value)
            #expect(throws: HarcBackgroundUploadHTTPV1Error.invalidAuthorization) {
                try HarcBackgroundUploadHTTPV1.parseRequestHead(head)
            }
        }

        var duplicate = makeHead(credential: credential)
        duplicate.headers.add(
            name: "Authorization",
            value: "HarcUpload " + canonical
        )
        #expect(throws: HarcBackgroundUploadHTTPV1Error.invalidAuthorization) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(duplicate)
        }
    }

    @Test("ambiguous or expanded body framing is rejected")
    func bodyFraming() throws {
        let credential = Data(repeating: 0xCC, count: 48)
        for value in ["", "0", "04096", "+4096"] {
            var head = makeHead(credential: credential)
            head.headers.remove(name: "Content-Length")
            head.headers.add(name: "Content-Length", value: value)
            #expect(throws: HarcBackgroundUploadHTTPV1Error.invalidContentLength) {
                try HarcBackgroundUploadHTTPV1.parseRequestHead(head)
            }
        }

        var oversized = makeHead(credential: credential)
        oversized.headers.remove(name: "Content-Length")
        oversized.headers.add(name: "Content-Length", value: "67108865")
        #expect(throws: HarcBackgroundUploadHTTPV1Error.bodyTooLarge) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(oversized)
        }

        var duplicate = makeHead(credential: credential)
        duplicate.headers.add(name: "Content-Length", value: "4096")
        #expect(throws: HarcBackgroundUploadHTTPV1Error.invalidContentLength) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(duplicate)
        }

        var chunked = makeHead(credential: credential)
        chunked.headers.add(name: "Transfer-Encoding", value: "chunked")
        #expect(
            throws: HarcBackgroundUploadHTTPV1Error
                .unsupportedTransferEncoding
        ) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(chunked)
        }

        var encoded = makeHead(credential: credential)
        encoded.headers.add(name: "Content-Encoding", value: "gzip")
        #expect(
            throws: HarcBackgroundUploadHTTPV1Error
                .unsupportedContentEncoding
        ) {
            try HarcBackgroundUploadHTTPV1.parseRequestHead(encoded)
        }
    }

    @Test("only 100-continue is admitted and every final response closes")
    func responseContract() throws {
        let credential = Data(repeating: 0xD1, count: 48)
        var expecting = makeHead(credential: credential)
        expecting.headers.add(name: "Expect", value: "100-Continue")
        #expect(
            try HarcBackgroundUploadHTTPV1.parseRequestHead(expecting)
                .expectsContinue
        )

        let acknowledgement = Data(repeating: 0x42, count: 128)
        let response = try HarcBackgroundUploadHTTPV1.makeSuccessResponse(
            exactAcknowledgementBytes: acknowledgement
        )
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Connection") == "close")
        #expect(response.head.headers.first(name: "Content-Length") == "128")
        #expect(Array(response.body.readableBytesView) == Array(acknowledgement))

        for status in [
            HTTPResponseStatus.badRequest,
            .unauthorized,
            .notFound,
            .payloadTooLarge,
            .internalServerError,
        ] {
            let head = HarcBackgroundUploadHTTPV1.makeErrorResponseHead(
                status: status
            )
            #expect(head.status.code >= 400)
            #expect(head.status.code < 600)
            #expect(head.headers.first(name: "Connection") == "close")
            #expect(head.headers.first(name: "Content-Length") == "0")
        }


        for error in [
            HarcBackgroundUploadHTTPV1Error.unsupportedHTTPVersion,
            .methodNotAllowed,
            .routeNotFound,
            .invalidAuthorization,
            .invalidContentType,
            .invalidContentLength,
            .bodyTooLarge,
            .unsupportedTransferEncoding,
            .unsupportedContentEncoding,
            .unsupportedTrailer,
            .invalidExpectHeader,
            .invalidHostHeader,
            .acknowledgementTooLarge,
        ] {
            let status = HarcBackgroundUploadHTTPV1.responseStatus(for: error)
            #expect(status.code >= 400)
            #expect(status.code < 600)
        }
    }

    private let uploadID = "abcdef12-3456-4789-8abc-def012345678"
    private let batchID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private var path: String {
        "/v1/uploads/\(uploadID)/batches/\(batchID)"
    }

    private func makeHead(credential: Data) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "harc-mini.local:7444")
        headers.add(
            name: "Authorization",
            value: "HarcUpload " + encodeBase64URL(credential)
        )
        headers.add(
            name: "Content-Type",
            value: HarcBackgroundUploadHTTPV1.requestContentType
        )
        headers.add(name: "Content-Length", value: "4096")
        return HTTPRequestHead(
            version: .http1_1,
            method: .PUT,
            uri: path,
            headers: headers
        )
    }

    private func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
