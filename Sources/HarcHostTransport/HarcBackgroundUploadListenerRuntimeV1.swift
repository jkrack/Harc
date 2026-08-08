#if canImport(Network)
import CryptoKit
import Darwin
import Foundation
import HarcDomain
import HarcHost
import HarcTransfer
import Network
import NIOCore
import NIOHTTP1
import NIOTransportServices

package enum HarcBackgroundUploadListenerRuntimeV1Error:
    Error, Equatable, Sendable
{
    case alreadyRunning
    case activationSuperseded
    case invalidTemporaryDirectory
    case temporaryIO(operation: String, code: Int32)
    case requestSequenceViolation
    case admissionBindingMismatch
    case bodyTooLong(expected: UInt64, actual: UInt64)
    case bodyTooShort(expected: UInt64, actual: UInt64)
    case bodyDigestMismatch
}

/// The transport-owned facts released by header admission. The ingest closure
/// captures HarcHost's opaque admission proof so no bearer secret or raw epoch
/// survives into body handling.
struct HarcBackgroundUploadTransportAdmissionV1: Sendable {
    let uploadID: UploadID
    let batchID: AudioBatchID
    let contentLength: UInt64
    let exactBodyByteLength: UInt64
    let exactBodySHA256: ImmutableBatchSHA256
    let byteCeiling: UInt64
    let ingest: @Sendable (URL) async throws -> Data
}

/// Creates one private directory per runtime and one exclusive 0600 file per
/// admitted request. The directory is always checked with `lstat`, so a
/// pre-existing symlink is never accepted as the upload root.
package struct HarcBackgroundUploadTemporaryBodyStoreV1: Sendable {
    package let rootDirectoryURL: URL

    package init(
        parentDirectory: URL,
        directoryID: UUID = UUID()
    ) throws {
        guard parentDirectory.isFileURL,
              parentDirectory.standardizedFileURL.path
                == parentDirectory.path else {
            throw HarcBackgroundUploadListenerRuntimeV1Error
                .invalidTemporaryDirectory
        }

        let root = parentDirectory.appendingPathComponent(
            "harc-background-upload-\(directoryID.uuidString.lowercased())",
            isDirectory: true
        )
        guard root.standardizedFileURL.path == root.path else {
            throw HarcBackgroundUploadListenerRuntimeV1Error
                .invalidTemporaryDirectory
        }

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                operation: "create-private-directory",
                code: Self.currentErrno(or: EIO)
            )
        }

        guard chmod(root.path, 0o700) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: root)
            throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                operation: "chmod-private-directory",
                code: code
            )
        }
        do {
            try Self.requirePrivateOwnedDirectory(at: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        rootDirectoryURL = root
    }

    func makeTemporaryBody() throws -> HarcBackgroundUploadTemporaryBodyV1 {
        try Self.requirePrivateOwnedDirectory(at: rootDirectoryURL)

        var template = Array(
            rootDirectoryURL
                .appendingPathComponent("body.XXXXXX", isDirectory: false)
                .path.utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                operation: "create-exclusive-body",
                code: errno
            )
        }
        let bodyPathBytes = template.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        }
        let bodyURL = URL(
            fileURLWithPath: String(decoding: bodyPathBytes, as: UTF8.self)
        )

        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                    operation: "chmod-body",
                    code: errno
                )
            }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                    operation: "close-on-exec-body",
                    code: errno
                )
            }
            try Self.requirePrivateOwnedFile(descriptor: descriptor)
            return HarcBackgroundUploadTemporaryBodyV1(
                url: bodyURL,
                descriptor: descriptor
            )
        } catch {
            let closeResult = Darwin.close(descriptor)
            _ = closeResult
            bodyURL.path.withCString { _ = Darwin.unlink($0) }
            throw error
        }
    }

    private static func requirePrivateOwnedDirectory(at url: URL) throws {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        guard result == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw HarcBackgroundUploadListenerRuntimeV1Error
                .invalidTemporaryDirectory
        }
    }

    private static func requirePrivateOwnedFile(
        descriptor: Int32
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw HarcBackgroundUploadListenerRuntimeV1Error.temporaryIO(
                operation: "stat-body",
                code: errno
            )
        }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_nlink == 1 else {
            throw HarcBackgroundUploadListenerRuntimeV1Error
                .invalidTemporaryDirectory
        }
    }

    private static func currentErrno(or fallback: Int32) -> Int32 {
        errno == 0 ? fallback : errno
    }
}

final class HarcBackgroundUploadTemporaryBodyV1: @unchecked Sendable {
    struct Finished: Sendable {
        let url: URL
        let byteCount: UInt64
        let sha256: ImmutableBatchSHA256
    }

    let url: URL

    private let queue = DispatchQueue(
        label: "xyz.harc.background-upload.temporary-body",
        qos: .utility
    )
    private var descriptor: Int32?
    private var byteCount: UInt64 = 0
    private var hasher = SHA256()

    init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    func append(
        _ buffer: ByteBuffer,
        expectedLength: UInt64
    ) async throws {
        guard let bytes = buffer.getBytes(
            at: buffer.readerIndex,
            length: buffer.readableBytes
        ) else {
            throw HarcBackgroundUploadListenerRuntimeV1Error
                .requestSequenceViolation
        }

        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let descriptor else {
                        throw HarcBackgroundUploadListenerRuntimeV1Error
                            .requestSequenceViolation
                    }
                    let fragmentLength = UInt64(bytes.count)
                    guard byteCount <= expectedLength,
                          fragmentLength <= expectedLength - byteCount else {
                        throw HarcBackgroundUploadListenerRuntimeV1Error
                            .bodyTooLong(
                                expected: expectedLength,
                                actual: byteCount + fragmentLength
                            )
                    }

                    try Self.writeAll(bytes, to: descriptor)
                    hasher.update(data: Data(bytes))
                    byteCount += fragmentLength
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func finish(expectedLength: UInt64) async throws -> Finished {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let descriptor else {
                        throw HarcBackgroundUploadListenerRuntimeV1Error
                            .requestSequenceViolation
                    }
                    guard byteCount == expectedLength else {
                        throw HarcBackgroundUploadListenerRuntimeV1Error
                            .bodyTooShort(
                                expected: expectedLength,
                                actual: byteCount
                            )
                    }
                    let digest = try ImmutableBatchSHA256(
                        Data(hasher.finalize())
                    )
                    guard Darwin.close(descriptor) == 0 else {
                        throw HarcBackgroundUploadListenerRuntimeV1Error
                            .temporaryIO(
                                operation: "close-body",
                                code: errno
                            )
                    }
                    self.descriptor = nil
                    continuation.resume(
                        returning: Finished(
                            url: url,
                            byteCount: byteCount,
                            sha256: digest
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func discard() {
        queue.sync { [self] in
            if let descriptor {
                _ = Darwin.close(descriptor)
                self.descriptor = nil
            }
            url.path.withCString { _ = Darwin.unlink($0) }
        }
    }

    private static func writeAll(
        _ bytes: [UInt8],
        to descriptor: Int32
    ) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw HarcBackgroundUploadListenerRuntimeV1Error
                        .temporaryIO(
                            operation: "write-body",
                            code: errno == 0 ? EIO : errno
                        )
                }
            }
        }
    }
}

/// One connection, one PUT, one final response. Admission happens before the
/// temporary file is created and before an optional informational response.
/// The async inbound stream supplies bounded backpressure while admission is
/// awaiting HostDB.
package struct HarcBackgroundUploadConnectionHandlerV1: Sendable {
    typealias Admit = @Sendable (
        HostBackgroundCapabilityAdmissionRequest,
        HarcBackgroundUploadServingGenerationBinding
    ) async throws -> HarcBackgroundUploadTransportAdmissionV1

    private let admit: Admit
    private let temporaryBodies: HarcBackgroundUploadTemporaryBodyStoreV1

    package init(
        application: HarcBackgroundBatchIngestApplicationV1,
        temporaryBodies: HarcBackgroundUploadTemporaryBodyStoreV1
    ) {
        self.temporaryBodies = temporaryBodies
        self.admit = { request, servingGeneration in
            let admission = try await application.admit(
                request,
                servedBy: servingGeneration
            )
            return HarcBackgroundUploadTransportAdmissionV1(
                uploadID: admission.batch.uploadID,
                batchID: admission.batch.batchID,
                contentLength: admission.contentLength,
                exactBodyByteLength:
                    admission.batch.exactBodyByteLength,
                exactBodySHA256: admission.exactBodySHA256,
                byteCeiling: admission.byteCeiling,
                ingest: { bodyURL in
                    try await application.ingest(
                        secureTemporaryBodyURL: bodyURL,
                        admission: admission
                    ).exactAcknowledgementBytes
                }
            )
        }
    }

    init(
        temporaryBodies: HarcBackgroundUploadTemporaryBodyStoreV1,
        admit: @escaping Admit
    ) {
        self.temporaryBodies = temporaryBodies
        self.admit = admit
    }

    package func handle(
        inbound: NIOAsyncChannelInboundStream<HTTPServerRequestPart>,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        servingGeneration: HarcBackgroundUploadServingGenerationBinding
    ) async {
        var temporaryBody: HarcBackgroundUploadTemporaryBodyV1?
        defer { temporaryBody?.discard() }

        do {
            var iterator = inbound.makeAsyncIterator()
            guard let firstPart = try await iterator.next() else { return }
            guard case .head(let requestHead) = firstPart else {
                try await writeError(.badRequest, to: outbound)
                return
            }

            let parsedHead: HarcBackgroundUploadHTTPRequestHeadV1
            do {
                parsedHead = try HarcBackgroundUploadHTTPV1
                    .parseRequestHead(requestHead)
            } catch let error as HarcBackgroundUploadHTTPV1Error {
#if DEBUG
                print("[Harc background-upload] request-head rejected: \(error)")
#endif
                try await writeError(
                    HarcBackgroundUploadHTTPV1.responseStatus(for: error),
                    to: outbound
                )
                return
            }

            let admissionRequest = HostBackgroundCapabilityAdmissionRequest(
                opaqueCapabilityCredential:
                    parsedHead.opaqueCapabilityCredential,
                httpMethod: "PUT",
                httpPath: parsedHead.exactPath,
                contentLength: parsedHead.contentLength
            )
            let admission: HarcBackgroundUploadTransportAdmissionV1
            do {
                admission = try await admit(
                    admissionRequest,
                    servingGeneration
                )
            } catch {
#if DEBUG
                print("[Harc background-upload] admission rejected: \(String(reflecting: error))")
#endif
                try await writeError(
                    Self.admissionFailureStatus(error),
                    to: outbound
                )
                return
            }

            guard admission.uploadID == parsedHead.uploadID,
                  admission.batchID == parsedHead.batchID,
                  admission.contentLength == parsedHead.contentLength,
                  admission.exactBodyByteLength == parsedHead.contentLength,
                  admission.contentLength <= admission.byteCeiling else {
                try await writeError(.internalServerError, to: outbound)
                return
            }

            do {
                temporaryBody = try temporaryBodies.makeTemporaryBody()
            } catch {
                try await writeError(.internalServerError, to: outbound)
                return
            }

            if parsedHead.expectsContinue {
                try await outbound.write(
                    .head(
                        HarcBackgroundUploadHTTPV1
                            .makeContinueResponseHead()
                    )
                )
            }

            while let part = try await iterator.next() {
                switch part {
                case .head:
                    try await writeError(.badRequest, to: outbound)
                    return
                case .body(let buffer):
                    do {
                        try await temporaryBody?.append(
                            buffer,
                            expectedLength: parsedHead.contentLength
                        )
                    } catch let error as
                        HarcBackgroundUploadListenerRuntimeV1Error {
                        try await writeError(
                            Self.bodyFailureStatus(error),
                            to: outbound
                        )
                        return
                    } catch {
                        try await writeError(
                            .internalServerError,
                            to: outbound
                        )
                        return
                    }
                case .end(let trailers):
                    guard trailers == nil || trailers?.isEmpty == true,
                          let temporaryBody else {
                        try await writeError(.badRequest, to: outbound)
                        return
                    }

                    let finished: HarcBackgroundUploadTemporaryBodyV1.Finished
                    do {
                        finished = try await temporaryBody.finish(
                            expectedLength: parsedHead.contentLength
                        )
                    } catch let error as
                        HarcBackgroundUploadListenerRuntimeV1Error {
                        try await writeError(
                            Self.bodyFailureStatus(error),
                            to: outbound
                        )
                        return
                    }

                    guard finished.byteCount == admission.contentLength,
                          finished.sha256
                            == admission.exactBodySHA256 else {
                        try await writeError(.badRequest, to: outbound)
                        return
                    }

                    let acknowledgement: Data
                    do {
                        acknowledgement = try await admission.ingest(
                            finished.url
                        )
                    } catch {
#if DEBUG
                        print("[Harc background-upload] ingest rejected: \(String(reflecting: error))")
#endif
                        try await writeError(
                            Self.ingestFailureStatus(error),
                            to: outbound
                        )
                        return
                    }

                    do {
                        let response = try HarcBackgroundUploadHTTPV1
                            .makeSuccessResponse(
                                exactAcknowledgementBytes: acknowledgement
                            )
                        try await outbound.write(
                            contentsOf: [
                                .head(response.head),
                                .body(.byteBuffer(response.body)),
                                .end(nil),
                            ]
                        )
#if DEBUG
                        print("[Harc background-upload] durable batch acknowledged")
#endif
                    } catch let error as HarcBackgroundUploadHTTPV1Error {
#if DEBUG
                        print("[Harc background-upload] acknowledgement response rejected: \(error)")
#endif
                        try await writeError(
                            HarcBackgroundUploadHTTPV1.responseStatus(
                                for: error
                            ),
                            to: outbound
                        )
                    }
                    return
                }
            }

            try await writeError(.badRequest, to: outbound)
        } catch {
#if DEBUG
            print("[Harc background-upload] connection failed: \(String(reflecting: error))")
#endif
            // A peer or pipeline failure can make writing impossible. If it is
            // still writable, return an empty, closing non-redirect response.
            try? await writeError(.badRequest, to: outbound)
        }
    }

    private func writeError(
        _ status: HTTPResponseStatus,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let head = HarcBackgroundUploadHTTPV1.makeErrorResponseHead(
            status: status
        )
        try await outbound.write(contentsOf: [.head(head), .end(nil)])
    }

    private static func admissionFailureStatus(
        _ error: any Error
    ) -> HTTPResponseStatus {
        guard let error = error as?
                HostBackgroundCapabilityAdmissionError else {
            return .internalServerError
        }
        switch error {
        case .credentialRejected, .capabilityUnavailable,
             .requestBindingMismatch, .transportSetEpochRejected:
            return .unauthorized
        case .acknowledgementMismatch:
            return .internalServerError
        }
    }

    package static func ingestFailureStatus(
        _ error: any Error
    ) -> HTTPResponseStatus {
        if let admissionError = error as?
            HostBackgroundCapabilityAdmissionError {
            return admissionFailureStatus(admissionError)
        }
        if let ingestError = error as? HarcBackgroundBatchIngestError {
            switch ingestError {
            case .immutableDescriptorMismatch:
                return .unprocessableEntity
            case .invalidRollbackRoot, .invalidServingGenerationBinding,
                 .rollbackIO, .stagedAcknowledgementMismatch:
                return .internalServerError
            }
        }
        if let hostError = error as? HarcHostError {
            switch hostError {
            case .insufficientFreeSpace, .quotaExceeded:
                return .insufficientStorage
            case .volumeCapacityUnavailable, .databaseFailure:
                return .serviceUnavailable
            default:
                break
            }
        }
        return .unprocessableEntity
    }

    private static func bodyFailureStatus(
        _ error: HarcBackgroundUploadListenerRuntimeV1Error
    ) -> HTTPResponseStatus {
        switch error {
        case .bodyTooLong, .bodyTooShort, .bodyDigestMismatch,
             .requestSequenceViolation:
            return .badRequest
        case .alreadyRunning, .activationSuperseded,
             .invalidTemporaryDirectory, .temporaryIO,
             .admissionBindingMismatch:
            return .internalServerError
        }
    }
}

private actor HarcBackgroundUploadRuntimeCompletionRaceV1 {
    private var resolved: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ value: Bool) {
        guard resolved == nil else { return }
        resolved = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters.removeAll()
    }

    func value() async -> Bool {
        if let resolved { return resolved }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private enum HarcBackgroundUploadSharedEventLoopsV1 {
    static let group = NIOTSEventLoopGroup(loopCount: 1)
}

/// Resident HTTP/1.1 upload listener. The supplied `NWListener` already owns
/// TLS and port selection; NIOTS wraps that exact listener instead of creating
/// a second socket or a second TLS identity.
package actor HarcBackgroundUploadListenerRuntimeV1:
    HarcBackgroundUploadListenerRuntimeBoundary
{
    private typealias ChildChannel = NIOAsyncChannel<
        HTTPServerRequestPart,
        HTTPServerResponsePart
    >

    private enum Phase: Equatable {
        case starting
        case running
        case draining
        case stopping
        case failed
    }

    private struct Current {
        let runtimeID: UUID
        let generationID: UUID
        let listener: NWListener
        let servingGeneration: HarcBackgroundUploadServingGenerationBinding
        let unexpectedExitHandler: @Sendable (UUID) async -> Void
        var phase: Phase
        var acceptor: (any Channel)?
        var children: [ObjectIdentifier: any Channel]
    }

    private let eventLoopGroup: NIOTSEventLoopGroup
    private let connectionHandler: HarcBackgroundUploadConnectionHandlerV1
    private let gracefulDrainTimeout: Duration
    private let hardStopTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var current: Current?
    private var childDrainWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var runtimeExitWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]

    package init(
        application: HarcBackgroundBatchIngestApplicationV1,
        temporaryParentDirectory: URL = FileManager.default
            .temporaryDirectory,
        eventLoopGroup: NIOTSEventLoopGroup? = nil,
        gracefulDrainTimeout: Duration = .seconds(20),
        hardStopTimeout: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) throws {
        let temporaryBodies = try
            HarcBackgroundUploadTemporaryBodyStoreV1(
                parentDirectory: temporaryParentDirectory
            )
        self.eventLoopGroup = eventLoopGroup
            ?? HarcBackgroundUploadSharedEventLoopsV1.group
        self.connectionHandler = HarcBackgroundUploadConnectionHandlerV1(
            application: application,
            temporaryBodies: temporaryBodies
        )
        self.gracefulDrainTimeout = gracefulDrainTimeout
        self.hardStopTimeout = hardStopTimeout
        self.sleep = sleep
    }

    init(
        connectionHandler: HarcBackgroundUploadConnectionHandlerV1,
        gracefulDrainTimeout: Duration = .seconds(20),
        hardStopTimeout: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.eventLoopGroup = HarcBackgroundUploadSharedEventLoopsV1.group
        self.connectionHandler = connectionHandler
        self.gracefulDrainTimeout = gracefulDrainTimeout
        self.hardStopTimeout = hardStopTimeout
        self.sleep = sleep
    }

    package func start(
        listener: NWListener,
        servingGeneration: HarcBackgroundUploadServingGenerationBinding,
        unexpectedExitHandler:
            @escaping @Sendable (UUID) async -> Void
    ) async throws {
        guard current == nil else {
            throw HarcBackgroundUploadListenerRuntimeV1Error.alreadyRunning
        }
        let runtimeID = UUID()
        current = Current(
            runtimeID: runtimeID,
            generationID: servingGeneration.generationID,
            listener: listener,
            servingGeneration: servingGeneration,
            unexpectedExitHandler: unexpectedExitHandler,
            phase: .starting,
            acceptor: nil,
            children: [:]
        )

        do {
            let serverChannel = try await NIOTSListenerBootstrap(
                group: eventLoopGroup
            )
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .withNWListener(
                listener,
                serverBackPressureStrategy: .init(
                    lowWatermark: 1,
                    highWatermark: 8
                )
            ) { channel -> EventLoopFuture<ChildChannel> in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations
                        .configureHTTPServerPipeline(
                            withPipeliningAssistance: false,
                            withErrorHandling: true,
                            withOutboundHeaderValidation: true
                        )
                    return try ChildChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            backPressureStrategy: .init(
                                lowWatermark: 1,
                                highWatermark: 4
                            )
                        )
                    )
                }
            }

            guard var generation = current,
                  generation.runtimeID == runtimeID,
                  generation.phase == .starting else {
                serverChannel.channel.close(promise: nil)
                throw HarcBackgroundUploadListenerRuntimeV1Error
                    .activationSuperseded
            }
            generation.phase = .running
            generation.acceptor = serverChannel.channel
            current = generation

            Task { [weak self] in
                await self?.serve(
                    serverChannel,
                    runtimeID: runtimeID
                )
            }
        } catch {
            if current?.runtimeID == runtimeID {
                current = nil
                resumeRuntimeExitWaiters(runtimeID: runtimeID)
            }
            throw error
        }
    }

    package func stopAcceptingNewConnections() async {
        guard var generation = current else { return }
        switch generation.phase {
        case .starting:
            generation.phase = .stopping
            current = generation
            generation.listener.cancel()
            return
        case .running, .failed:
            generation.phase = .draining
            current = generation
        case .draining, .stopping:
            return
        }
        generation.acceptor?.close(promise: nil)
        if let acceptor = generation.acceptor {
            _ = try? await acceptor.closeFuture.get()
        }
    }

    package func finishGracefulShutdown() async {
        guard let generation = current else { return }
        if generation.phase == .starting
            || (generation.phase == .stopping
                && generation.acceptor == nil) {
            generation.listener.cancel()
            _ = await runtimeExits(
                runtimeID: generation.runtimeID,
                before: hardStopTimeout
            )
            return
        }

        let drained = await childrenDrain(
            runtimeID: generation.runtimeID,
            before: gracefulDrainTimeout
        )
        if !drained {
            closeChildren(runtimeID: generation.runtimeID)
            _ = await childrenDrain(
                runtimeID: generation.runtimeID,
                before: hardStopTimeout
            )
        }
        clearStoppedGenerationIfPossible(runtimeID: generation.runtimeID)
    }

    package func stopImmediately() async {
        guard var generation = current else { return }
        generation.phase = .stopping
        current = generation
        generation.listener.cancel()
        generation.acceptor?.close(promise: nil)
        closeChildren(runtimeID: generation.runtimeID)

        _ = await runtimeExits(
            runtimeID: generation.runtimeID,
            before: hardStopTimeout
        )
        _ = await childrenDrain(
            runtimeID: generation.runtimeID,
            before: hardStopTimeout
        )
        clearStoppedGenerationIfPossible(runtimeID: generation.runtimeID)
    }

    private func serve(
        _ serverChannel: NIOAsyncChannel<ChildChannel, Never>,
        runtimeID: UUID
    ) async {
        do {
            try await serverChannel.executeThenClose { inbound in
                for try await child in inbound {
                    accept(child, runtimeID: runtimeID)
                }
            }
        } catch {
            // Completion classification below is intentionally independent of
            // the error text and never logs a capability-bearing request.
        }
        await acceptorExited(runtimeID: runtimeID)
    }

    private func accept(_ child: ChildChannel, runtimeID: UUID) {
        guard var generation = current,
              generation.runtimeID == runtimeID,
              generation.phase == .running else {
            child.channel.close(promise: nil)
            return
        }

        let childID = ObjectIdentifier(child.channel)
        generation.children[childID] = child.channel
        let servingGeneration = generation.servingGeneration
        current = generation
        let connectionHandler = self.connectionHandler

        Task { [weak self] in
            do {
                try await child.executeThenClose { inbound, outbound in
                    await connectionHandler.handle(
                        inbound: inbound,
                        outbound: outbound,
                        servingGeneration: servingGeneration
                    )
                }
            } catch {
                child.channel.close(promise: nil)
            }
            await self?.childExited(
                childID: childID,
                runtimeID: runtimeID
            )
        }
    }

    private func childExited(
        childID: ObjectIdentifier,
        runtimeID: UUID
    ) {
        guard var generation = current,
              generation.runtimeID == runtimeID else { return }
        generation.children.removeValue(forKey: childID)
        current = generation
        if generation.children.isEmpty {
            resumeChildDrainWaiters(runtimeID: runtimeID)
            clearStoppedGenerationIfPossible(runtimeID: runtimeID)
        }
    }

    private func acceptorExited(runtimeID: UUID) async {
        guard var generation = current,
              generation.runtimeID == runtimeID else {
            resumeRuntimeExitWaiters(runtimeID: runtimeID)
            return
        }
        generation.acceptor = nil

        let reportUnexpected: Bool
        switch generation.phase {
        case .running:
            generation.phase = .failed
            reportUnexpected = true
        case .starting, .draining, .stopping, .failed:
            reportUnexpected = false
        }
        current = generation
        resumeRuntimeExitWaiters(runtimeID: runtimeID)
        clearStoppedGenerationIfPossible(runtimeID: runtimeID)

        if reportUnexpected {
            await generation.unexpectedExitHandler(
                generation.generationID
            )
        }
    }

    private func closeChildren(runtimeID: UUID) {
        guard let generation = current,
              generation.runtimeID == runtimeID else { return }
        for child in generation.children.values {
            child.close(promise: nil)
        }
    }

    private func clearStoppedGenerationIfPossible(runtimeID: UUID) {
        guard let generation = current,
              generation.runtimeID == runtimeID,
              generation.acceptor == nil,
              generation.children.isEmpty,
              (generation.phase == .draining
                || generation.phase == .stopping) else { return }
        current = nil
        resumeChildDrainWaiters(runtimeID: runtimeID)
        resumeRuntimeExitWaiters(runtimeID: runtimeID)
    }

    private func waitForChildrenToDrain(runtimeID: UUID) async {
        guard let generation = current,
              generation.runtimeID == runtimeID,
              !generation.children.isEmpty else { return }
        await withCheckedContinuation {
            childDrainWaiters[runtimeID, default: []].append($0)
        }
    }

    private func waitForRuntimeExit(runtimeID: UUID) async {
        guard let generation = current,
              generation.runtimeID == runtimeID,
              generation.acceptor != nil
                || generation.phase == .starting
                || generation.phase == .stopping else { return }
        await withCheckedContinuation {
            runtimeExitWaiters[runtimeID, default: []].append($0)
        }
    }

    private func childrenDrain(
        runtimeID: UUID,
        before timeout: Duration
    ) async -> Bool {
        let race = HarcBackgroundUploadRuntimeCompletionRaceV1()
        let completionTask = Task { [weak self] in
            await self?.waitForChildrenToDrain(runtimeID: runtimeID)
            await race.resolve(true)
        }
        let timeoutTask = Task { [sleep] in
            do {
                try await sleep(timeout)
            } catch {
                guard !Task.isCancelled else { return }
                await race.resolve(false)
                return
            }
            guard !Task.isCancelled else { return }
            await race.resolve(false)
        }
        let result = await race.value()
        completionTask.cancel()
        timeoutTask.cancel()
        return result
    }

    private func runtimeExits(
        runtimeID: UUID,
        before timeout: Duration
    ) async -> Bool {
        let race = HarcBackgroundUploadRuntimeCompletionRaceV1()
        let completionTask = Task { [weak self] in
            await self?.waitForRuntimeExit(runtimeID: runtimeID)
            await race.resolve(true)
        }
        let timeoutTask = Task { [sleep] in
            do {
                try await sleep(timeout)
            } catch {
                guard !Task.isCancelled else { return }
                await race.resolve(false)
                return
            }
            guard !Task.isCancelled else { return }
            await race.resolve(false)
        }
        let result = await race.value()
        completionTask.cancel()
        timeoutTask.cancel()
        return result
    }

    private func resumeChildDrainWaiters(runtimeID: UUID) {
        let waiters = childDrainWaiters.removeValue(forKey: runtimeID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func resumeRuntimeExitWaiters(runtimeID: UUID) {
        let waiters = runtimeExitWaiters.removeValue(forKey: runtimeID) ?? []
        for waiter in waiters { waiter.resume() }
    }
}
#endif
