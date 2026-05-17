import Foundation
import Testing
@testable import HarcUI

private struct SampleMutationError: LocalizedError {
    var errorDescription: String? { "Disk permission denied" }
}

struct LibraryMutationFailureTests {
    @Test("delete recording failure names the failed recording")
    func deleteRecordingFailureMessage() {
        let failure = LibraryMutationFailure(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000056")!,
            action: .deleteRecording("Design review"),
            error: SampleMutationError()
        )

        #expect(failure.title == "Could not delete recording")
        #expect(failure.message == "Design review: Disk permission denied")
    }

    @Test("speaker mutation failure uses actionable speaker copy")
    func speakerMutationFailureMessage() {
        let failure = LibraryMutationFailure(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000057")!,
            action: .linkSpeaker,
            error: SampleMutationError()
        )

        #expect(failure.title == "Could not link speaker")
        #expect(failure.message == "Disk permission denied")
    }
}
