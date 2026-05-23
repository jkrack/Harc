import Foundation
import Testing
@testable import HarcModels

@Suite("VisionCaptionService")
struct VisionCaptionServiceTests {
    @Test("caption uses injected generator when model directory exists")
    func captionUsesInjectedGenerator() async throws {
        let modelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-vision-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let imageURL = modelDir.appendingPathComponent("slide.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let service = VisionCaptionService { request in
            #expect(request.prompt == VisionCaptionRequest.defaultPrompt)
            return "  A roadmap slide with three launch milestones.  "
        }

        let caption = try await service.caption(VisionCaptionRequest(
            imageURL: imageURL,
            modelID: "test-captioner",
            modelDirectory: modelDir
        ))

        #expect(caption == "A roadmap slide with three launch milestones.")
    }

    @Test("caption fails when model directory is missing")
    func captionRequiresModelDirectory() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-harc-vision-model-\(UUID().uuidString)", isDirectory: true)
        let service = VisionCaptionService { _ in "caption" }

        await #expect(throws: VisionCaptionError.modelUnavailable("missing-model")) {
            _ = try await service.caption(VisionCaptionRequest(
                imageURL: missing.appendingPathComponent("slide.png"),
                modelID: "missing-model",
                modelDirectory: missing
            ))
        }
    }
}
