import Foundation
import HarcProtocol
import Testing
@testable import HarcClientTransport

@Suite("Recording-transfer client transport")
struct HarcRecordingTransferRPCTransportTests {
    @Test("authorization accepts only the canonical header for the opened credential")
    func canonicalAuthorization() throws {
        let credential = Data((0 ..< 48).map { UInt8($0) })
        let header = try HarcBootstrapAuthorization.sessionHeader(
            credential: credential
        )

        _ = try HarcRecordingTransferAuthorization(
            credential: credential,
            authorizationHeader: header
        )

        #expect(throws: HarcRecordingTransferAuthorizationError
            .invalidOpenedSessionAuthorization) {
            _ = try HarcRecordingTransferAuthorization(
                credential: credential,
                authorizationHeader: header + "="
            )
        }
        #expect(throws: HarcRecordingTransferAuthorizationError
            .invalidOpenedSessionAuthorization) {
            _ = try HarcRecordingTransferAuthorization(
                credential: Data(credential.dropLast()),
                authorizationHeader: header
            )
        }
        #expect(throws: HarcRecordingTransferAuthorizationError
            .invalidOpenedSessionAuthorization) {
            _ = try HarcRecordingTransferAuthorization(
                credential: credential,
                authorizationHeader: header.replacingOccurrences(
                    of: "HarcSession ",
                    with: "Bearer "
                )
            )
        }
    }

    @Test("chunk writer preserves underlying backpressure")
    func chunkWriterBackpressure() async throws {
        let probe = SuspendedChunkWriteProbe()
        let writer = HarcUploadChunkRequestWriter { request in
            await probe.write(request)
        }

        let task = Task {
            try await writer.write(Harc_V1_UploadChunkRequestV1())
        }
        await probe.waitUntilStarted()
        #expect(await probe.hasCompleted() == false)

        await probe.release()
        try await task.value
        #expect(await probe.hasCompleted())
    }

    @Test("the public seam is fakeable and streams requests and responses incrementally")
    func fakeTransportFeasibility() async throws {
        let credential = Data(repeating: 0xa5, count: 48)
        let authorization = try HarcRecordingTransferAuthorization(
            credential: credential,
            authorizationHeader: HarcBootstrapAuthorization.sessionHeader(
                credential: credential
            )
        )
        let fake = RecordingTransferFake()
        let transport: any HarcRecordingTransferRPCTransport = fake

        _ = try await transport.beginUpload(
            Harc_V1_BeginUploadRequestV1(),
            authorization: authorization
        )
        _ = try await transport.declareChunks(
            Harc_V1_DeclareChunksRequestV1(),
            authorization: authorization
        )

        let responseProbe = UploadResponseProbe()
        try await transport.uploadChunks(
            authorization: authorization,
            requestProducer: { writer in
                try await writer.write(Harc_V1_UploadChunkRequestV1())
                try await writer.write(Harc_V1_UploadChunkRequestV1())
            },
            responseConsumer: { _ in
                await responseProbe.record()
            }
        )

        _ = try await transport.reconcileUpload(
            Harc_V1_ReconcileUploadRequestV1(),
            authorization: authorization
        )
        _ = try await transport.commitUpload(
            Harc_V1_CommitUploadRequestV1(),
            authorization: authorization
        )
        _ = try await transport.abandonUpload(
            Harc_V1_AbandonUploadRequestV1(),
            authorization: authorization
        )
        _ = try await transport.getRecordingStatus(
            Harc_V1_GetRecordingStatusRequestV1(),
            authorization: authorization
        )
        _ = try await transport.mintBackgroundUploadAuthorization(
            Harc_V1_MintBackgroundCapabilityRequestV1(),
            authorization: authorization
        )

        #expect(await fake.uploadedRequestCount() == 2)
        #expect(await responseProbe.count() == 2)
        #expect(await fake.recordedCalls() == [
            "beginUpload",
            "declareChunks",
            "uploadChunks",
            "reconcileUpload",
            "commitUpload",
            "abandonUpload",
            "getRecordingStatus",
            "mintBackgroundUploadAuthorization",
        ])
    }
}

private actor SuspendedChunkWriteProbe {
    private var started = false
    private var completed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func write(_: Harc_V1_UploadChunkRequestV1) async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        completed = true
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func hasCompleted() -> Bool {
        completed
    }
}

private actor UploadResponseProbe {
    private var responseCount = 0

    func record() {
        responseCount += 1
    }

    func count() -> Int {
        responseCount
    }
}

private actor RecordingTransferFake: HarcRecordingTransferRPCTransport {
    private var calls: [String] = []
    private var uploadedRequests = 0

    func beginUpload(
        _: Harc_V1_BeginUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_BeginUploadResponseV1 {
        calls.append("beginUpload")
        return Harc_V1_BeginUploadResponseV1()
    }

    func declareChunks(
        _: Harc_V1_DeclareChunksRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_DeclareChunksResponseV1 {
        calls.append("declareChunks")
        return Harc_V1_DeclareChunksResponseV1()
    }

    func uploadChunks(
        authorization _: HarcRecordingTransferAuthorization,
        requestProducer: @escaping HarcUploadChunkRequestProducer,
        responseConsumer: @escaping HarcUploadChunkResponseConsumer
    ) async throws {
        calls.append("uploadChunks")
        try await requestProducer(HarcUploadChunkRequestWriter { _ in
            await self.recordUploadedRequest()
            try await responseConsumer(Harc_V1_UploadChunkResponseV1())
        })
    }

    func reconcileUpload(
        _: Harc_V1_ReconcileUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_ReconcileUploadResponseV1 {
        calls.append("reconcileUpload")
        return Harc_V1_ReconcileUploadResponseV1()
    }

    func commitUpload(
        _: Harc_V1_CommitUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_CommitUploadResponseV1 {
        calls.append("commitUpload")
        return Harc_V1_CommitUploadResponseV1()
    }

    func abandonUpload(
        _: Harc_V1_AbandonUploadRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_AbandonUploadResponseV1 {
        calls.append("abandonUpload")
        return Harc_V1_AbandonUploadResponseV1()
    }

    func getRecordingStatus(
        _: Harc_V1_GetRecordingStatusRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_GetRecordingStatusResponseV1 {
        calls.append("getRecordingStatus")
        return Harc_V1_GetRecordingStatusResponseV1()
    }

    func mintBackgroundUploadAuthorization(
        _: Harc_V1_MintBackgroundCapabilityRequestV1,
        authorization _: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        calls.append("mintBackgroundUploadAuthorization")
        return Harc_V1_MintBackgroundCapabilityResponseV1()
    }

    func recordedCalls() -> [String] {
        calls
    }

    func uploadedRequestCount() -> Int {
        uploadedRequests
    }

    private func recordUploadedRequest() {
        uploadedRequests += 1
    }
}
