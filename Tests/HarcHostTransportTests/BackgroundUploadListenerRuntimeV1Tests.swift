#if canImport(Network)
import CryptoKit
import Darwin
import Foundation
import HarcDomain
import HarcHost
@testable import HarcHostTransport
import HarcTransfer
import Network
import NIOCore
import NIOHTTP1
import Testing

@Suite("Background upload listener runtime")
struct BackgroundUploadListenerRuntimeV1Tests {
    @Test("storage pressure maps to a retryable HTTP status")
    func storagePressureStatus() {
        #expect(
            HarcBackgroundUploadConnectionHandlerV1.ingestFailureStatus(
                HarcHostError.insufficientFreeSpace(
                    requiredRemaining: 20,
                    projectedRemaining: 10
                )
            ) == .insufficientStorage
        )
        #expect(
            HarcBackgroundUploadConnectionHandlerV1.ingestFailureStatus(
                HarcHostError.volumeCapacityUnavailable
            ) == .serviceUnavailable
        )
    }

    @Test("admitted body is hashed in a private file before exact ACK")
    func admittedBodyAndExactAcknowledgement() async throws {
        let parent = try makeTemporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bodies = try HarcBackgroundUploadTemporaryBodyStoreV1(
            parentDirectory: parent
        )
        let rootMetadata = try metadata(at: bodies.rootDirectoryURL)
        #expect(rootMetadata.st_uid == geteuid())
        #expect(rootMetadata.st_mode & mode_t(0o777) == mode_t(0o700))
        #expect(rootMetadata.st_mode & S_IFMT == S_IFDIR)

        let body = Data("one admitted immutable body".utf8)
        let acknowledgement = Data("exact-signed-acknowledgement".utf8)
        let digest = try immutableDigest(body)
        let observation = RuntimeBodyObservation(
            expectedBody: body,
            acknowledgement: acknowledgement
        )
        let handler = HarcBackgroundUploadConnectionHandlerV1(
            temporaryBodies: bodies
        ) { request, _ in
            #expect(request.httpMethod == "PUT")
            #expect(request.httpPath == canonicalPath)
            #expect(request.contentLength == UInt64(body.count))
            return transportAdmission(
                bodyLength: UInt64(body.count),
                digest: digest
            ) { url in
                try await observation.ingest(url)
            }
        }

        let responses = await run(
            handler: handler,
            requestHead: makeHead(
                contentLength: body.count,
                expectsContinue: true
            ),
            requestParts: [
                .body(ByteBuffer(bytes: body)),
                .end(nil),
            ]
        )

        #expect(responses.count == 4)
        guard responses.count == 4 else { return }
        guard case .head(let informational) = responses[0] else {
            Issue.record("first response was not 100 Continue")
            return
        }
        #expect(informational.status == .continue)

        guard case .head(let success) = responses[1] else {
            Issue.record("final response did not begin with a head")
            return
        }
        #expect(success.status == .ok)
        #expect(success.headers.first(name: "Cache-Control") == "no-store")
        #expect(success.headers.first(name: "Connection") == "close")
        #expect(success.headers.first(name: "Location") == nil)

        guard case .body(.byteBuffer(let ackBuffer)) = responses[2] else {
            Issue.record("final response did not contain the exact ACK")
            return
        }
        #expect(Data(ackBuffer.readableBytesView) == acknowledgement)
        guard case .end(nil) = responses[3] else {
            Issue.record("final response did not terminate exactly once")
            return
        }

        let snapshot = await observation.snapshot()
        #expect(snapshot.ingestCount == 1)
        #expect(snapshot.observedBody == body)
        #expect(snapshot.owner == geteuid())
        #expect(snapshot.permissions == mode_t(0o600))
        #expect(snapshot.fileKind == S_IFREG)
        #expect(try directoryEntries(at: bodies.rootDirectoryURL).isEmpty)
    }

    @Test("rejected Expect request sends no 100 and creates no body file")
    func rejectionPrecedesContinueAndFileCreation() async throws {
        let parent = try makeTemporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bodies = try HarcBackgroundUploadTemporaryBodyStoreV1(
            parentDirectory: parent
        )
        let handler = HarcBackgroundUploadConnectionHandlerV1(
            temporaryBodies: bodies
        ) { _, _ in
            throw HostBackgroundCapabilityAdmissionError.credentialRejected
        }

        let responses = await run(
            handler: handler,
            requestHead: makeHead(
                contentLength: 32,
                expectsContinue: true
            ),
            requestParts: []
        )

        #expect(responses.count == 2)
        guard responses.count == 2,
              case .head(let rejection) = responses[0] else { return }
        #expect(rejection.status == .unauthorized)
        #expect(rejection.status != .continue)
        #expect(rejection.headers.first(name: "Connection") == "close")
        #expect(rejection.headers.first(name: "Location") == nil)
        #expect(try directoryEntries(at: bodies.rootDirectoryURL).isEmpty)
    }

    @Test("short and long bodies are rejected and their files are removed")
    func exactLengthEnforcement() async throws {
        for body in [Data("abc".utf8), Data("abcde".utf8)] {
            let parent = try makeTemporaryParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let bodies = try HarcBackgroundUploadTemporaryBodyStoreV1(
                parentDirectory: parent
            )
            let handler = HarcBackgroundUploadConnectionHandlerV1(
                temporaryBodies: bodies
            ) { _, _ in
                transportAdmission(
                    bodyLength: 4,
                    digest: try immutableDigest(Data("abcd".utf8))
                ) { _ in
                    Issue.record("ingest ran for an inexact body")
                    return Data("must-not-be-returned".utf8)
                }
            }

            let responses = await run(
                handler: handler,
                requestHead: makeHead(
                    contentLength: 4,
                    expectsContinue: false
                ),
                requestParts: [
                    .body(ByteBuffer(bytes: body)),
                    .end(nil),
                ]
            )

            #expect(responses.count == 2)
            guard responses.count == 2,
                  case .head(let rejection) = responses[0] else {
                continue
            }
            #expect(rejection.status == .badRequest)
            #expect(rejection.headers.first(name: "Connection") == "close")
            #expect(rejection.headers.first(name: "Location") == nil)
            #expect(try directoryEntries(at: bodies.rootDirectoryURL).isEmpty)
        }
    }

    @Test("immediate stop fully releases the acceptor before restart")
    func restartAfterImmediateStop() async throws {
        let parent = try makeTemporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bodies = try HarcBackgroundUploadTemporaryBodyStoreV1(
            parentDirectory: parent
        )
        let handler = HarcBackgroundUploadConnectionHandlerV1(
            temporaryBodies: bodies
        ) { _, _ in
            throw HostBackgroundCapabilityAdmissionError.credentialRejected
        }
        let runtime = HarcBackgroundUploadListenerRuntimeV1(
            connectionHandler: handler,
            gracefulDrainTimeout: .seconds(1),
            hardStopTimeout: .seconds(1)
        )

        let firstGeneration = try servingGeneration(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000a01"
            )!,
            epoch: 1
        )
        try await runtime.start(
            listener: try NWListener(using: .tcp, on: .any),
            servingGeneration: firstGeneration,
            unexpectedExitHandler: { _ in
                Issue.record("intentional stop was reported as unexpected")
            }
        )
        await runtime.stopImmediately()

        let secondGeneration = try servingGeneration(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000a02"
            )!,
            epoch: 2
        )
        try await runtime.start(
            listener: try NWListener(using: .tcp, on: .any),
            servingGeneration: secondGeneration,
            unexpectedExitHandler: { _ in
                Issue.record("intentional stop was reported as unexpected")
            }
        )
        await runtime.stopImmediately()
    }

    @Test("Network.framework listener accepts a child connection")
    func acceptsNetworkFrameworkChildConnection() async throws {
        let parent = try makeTemporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bodies = try HarcBackgroundUploadTemporaryBodyStoreV1(
            parentDirectory: parent
        )
        let handler = HarcBackgroundUploadConnectionHandlerV1(
            temporaryBodies: bodies
        ) { _, _ in
            throw HostBackgroundCapabilityAdmissionError.credentialRejected
        }
        let runtime = HarcBackgroundUploadListenerRuntimeV1(
            connectionHandler: handler,
            gracefulDrainTimeout: .seconds(1),
            hardStopTimeout: .seconds(1)
        )
        let listener = try NWListener(using: .tcp, on: .any)

        try await runtime.start(
            listener: listener,
            servingGeneration: try servingGeneration(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000a03"
                )!,
                epoch: 3
            ),
            unexpectedExitHandler: { _ in
                Issue.record("live listener exited unexpectedly")
            }
        )
        defer { Task { await runtime.stopImmediately() } }

        let port = try #require(listener.port)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.rawValue).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        #expect(result == 0)

        try await Task.sleep(for: .milliseconds(100))
        await runtime.stopImmediately()
    }

    private func run(
        handler: HarcBackgroundUploadConnectionHandlerV1,
        requestHead: HTTPRequestHead,
        requestParts: [HTTPServerRequestPart]
    ) async -> [HTTPServerResponsePart] {
        let (inbound, source) = NIOAsyncChannelInboundStream<
            HTTPServerRequestPart
        >.makeTestingStream()
        let (outbound, sink) = NIOAsyncChannelOutboundWriter<
            HTTPServerResponsePart
        >.makeTestingWriter()

        source.yield(.head(requestHead))
        for part in requestParts { source.yield(part) }
        source.finish()
        await handler.handle(
            inbound: inbound,
            outbound: outbound,
            servingGeneration: try! servingGeneration(
                id: generationID,
                epoch: 7
            )
        )
        outbound.finish()

        var responses: [HTTPServerResponsePart] = []
        for await response in sink { responses.append(response) }
        return responses
    }

    private func transportAdmission(
        bodyLength: UInt64,
        digest: ImmutableBatchSHA256,
        ingest: @escaping @Sendable (URL) async throws -> Data
    ) -> HarcBackgroundUploadTransportAdmissionV1 {
        HarcBackgroundUploadTransportAdmissionV1(
            uploadID: uploadID,
            batchID: batchID,
            contentLength: bodyLength,
            exactBodyByteLength: bodyLength,
            exactBodySHA256: digest,
            byteCeiling: bodyLength,
            ingest: ingest
        )
    }

    private func makeHead(
        contentLength: Int,
        expectsContinue: Bool
    ) -> HTTPRequestHead {
        let credential = Data(repeating: 0xA7, count: 48)
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "harc-host.local:7444")
        headers.add(
            name: "Authorization",
            value: "HarcUpload " + base64URL(credential)
        )
        headers.add(
            name: "Content-Type",
            value: HarcBackgroundUploadHTTPV1.requestContentType
        )
        headers.add(
            name: "Content-Length",
            value: String(contentLength)
        )
        if expectsContinue {
            headers.add(name: "Expect", value: "100-continue")
        }
        return HTTPRequestHead(
            version: .http1_1,
            method: .PUT,
            uri: canonicalPath,
            headers: headers
        )
    }

    private func servingGeneration(
        id: UUID,
        epoch: UInt64
    ) throws -> HarcBackgroundUploadServingGenerationBinding {
        try HarcBackgroundUploadServingGenerationBinding(
            generationID: id,
            transportSetEpoch: epoch
        )
    }

    private func immutableDigest(
        _ data: Data
    ) throws -> ImmutableBatchSHA256 {
        try ImmutableBatchSHA256(Data(SHA256.hash(data: data)))
    }

    private func makeTemporaryParent() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "harc-upload-runtime-tests-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func directoryEntries(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    private func metadata(at url: URL) throws -> stat {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            throw RuntimeTestError.posix(operation: "lstat", code: errno)
        }
        return metadata
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private var uploadID: UploadID {
        UploadID(
            UUID(
                uuidString: "abcdef12-3456-4789-8abc-def012345678"
            )!
        )
    }

    private var batchID: AudioBatchID {
        AudioBatchID(
            UUID(
                uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            )!
        )
    }

    private var canonicalPath: String {
        "/v1/uploads/\(uploadID)/batches/\(batchID)"
    }

    private var generationID: UUID {
        UUID(
            uuidString: "00000000-0000-0000-0000-000000000a00"
        )!
    }
}

private actor RuntimeBodyObservation {
    struct Snapshot: Sendable {
        let ingestCount: Int
        let observedBody: Data?
        let owner: uid_t?
        let permissions: mode_t?
        let fileKind: mode_t?
    }

    private let expectedBody: Data
    private let acknowledgement: Data
    private var ingestCount = 0
    private var observedBody: Data?
    private var owner: uid_t?
    private var permissions: mode_t?
    private var fileKind: mode_t?

    init(expectedBody: Data, acknowledgement: Data) {
        self.expectedBody = expectedBody
        self.acknowledgement = acknowledgement
    }

    func ingest(_ url: URL) throws -> Data {
        let body = try Data(contentsOf: url)
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0 else {
            throw RuntimeTestError.posix(operation: "lstat", code: errno)
        }
        guard body == expectedBody else {
            throw RuntimeTestError.unexpectedBody
        }
        ingestCount += 1
        observedBody = body
        owner = metadata.st_uid
        permissions = metadata.st_mode & mode_t(0o777)
        fileKind = metadata.st_mode & S_IFMT
        return acknowledgement
    }

    func snapshot() -> Snapshot {
        Snapshot(
            ingestCount: ingestCount,
            observedBody: observedBody,
            owner: owner,
            permissions: permissions,
            fileKind: fileKind
        )
    }
}

private enum RuntimeTestError: Error {
    case posix(operation: String, code: Int32)
    case unexpectedBody
}
#endif
