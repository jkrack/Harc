import Foundation
import HarcProtocol
import Testing
@testable import Harc

@Suite("Desktop processing artifact framing")
struct HarcDesktopProcessingArtifactTests {
    @Test("bundle requests begin once and preserve contiguous one-MiB frames")
    func requestsAreContiguous() throws {
        let bundle = Data(
            repeating: 0xa5,
            count: HarcProcessingBundleV1.maximumHeaderBytes + 37
        )
        let submission = HarcDesktopProcessingSubmission(
            exactSignedMetadata: Data("signed".utf8),
            exactBundle: bundle
        )
        let requests = HarcDesktopProcessingArtifactBuilder.requests(
            for: submission
        )
        #expect(requests.count == 3)
        guard case .begin(let begin) = requests[0].value else {
            Issue.record("First request was not begin")
            return
        }
        #expect(
            begin.exactSignedProcessingArtifact.framedBytes
                == submission.exactSignedMetadata
        )

        var reconstructed = Data()
        for (position, request) in requests.dropFirst().enumerated() {
            guard case .frame(let frame) = request.value else {
                Issue.record("Request was not a frame")
                return
            }
            #expect(frame.frameIndex == UInt32(position))
            #expect(frame.byteOffset == UInt64(reconstructed.count))
            #expect(!frame.data.isEmpty)
            #expect(
                frame.data.count
                    <= HarcProcessingBundleV1.maximumHeaderBytes
            )
            reconstructed.append(frame.data)
        }
        #expect(reconstructed == bundle)
    }
}
