import Foundation
import HarcProtocol
import Testing
@testable import HarcClientTransport

@Suite("Processing client transport")
struct HarcProcessingRPCTransportTests {
    @Test("public processing seam preserves ordered backpressured writes")
    func fakeTransport() async throws {
        let authorization = HarcProcessingAuthorization(
            validatedHeaderValueForTesting: "HarcSession test"
        )
        let fake = ProcessingTransportFake()
        let transport: any HarcProcessingRPCTransport = fake
        let response = try await transport.submitOwnArtifact(
            authorization: authorization,
            requestProducer: { writer in
                var begin = Harc_V1_SubmitOwnArtifactRequestV1()
                begin.value = .begin(Harc_V1_ProcessingSubmissionBeginV1())
                try await writer.write(begin)
                var frame = Harc_V1_SubmitOwnArtifactRequestV1()
                frame.value = .frame(Harc_V1_ProcessingBundleFrameV1())
                try await writer.write(frame)
            }
        )
        #expect(
            response.disposition
                == .processingSubmissionDispositionHostProcessingScheduled
        )
        #expect(await fake.values() == ["begin", "frame"])
        _ = try await transport.getProcessingStatus(
            Harc_V1_GetProcessingStatusRequestV1(),
            authorization: authorization
        )
        #expect(await fake.statusCallCount() == 1)
    }
}

private actor ProcessingTransportFake: HarcProcessingRPCTransport {
    private var recordedValues: [String] = []
    private var statusCalls = 0

    func submitOwnArtifact(
        authorization: HarcProcessingAuthorization,
        requestProducer: @escaping HarcProcessingRequestProducer
    ) async throws -> Harc_V1_SubmitOwnArtifactResponseV1 {
        try await requestProducer(HarcProcessingRequestWriter { request in
            await self.record(request)
        })
        var response = Harc_V1_SubmitOwnArtifactResponseV1()
        response.disposition =
            .processingSubmissionDispositionHostProcessingScheduled
        return response
    }

    func getProcessingStatus(
        _ request: Harc_V1_GetProcessingStatusRequestV1,
        authorization: HarcProcessingAuthorization
    ) async throws -> Harc_V1_GetProcessingStatusResponseV1 {
        statusCalls += 1
        return Harc_V1_GetProcessingStatusResponseV1()
    }

    func values() -> [String] { recordedValues }
    func statusCallCount() -> Int { statusCalls }

    private func record(_ request: Harc_V1_SubmitOwnArtifactRequestV1) {
        switch request.value {
        case .begin: recordedValues.append("begin")
        case .frame: recordedValues.append("frame")
        case nil: recordedValues.append("nil")
        }
    }
}
