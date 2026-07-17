import Testing
@testable import HarcUI

@MainActor
struct WelcomeFlowModelTests {
    @Test("welcome flow supports forward, back, and direct step selection")
    func navigation() {
        let model = WelcomeFlowModel()

        #expect(model.selectedIndex == 0)
        #expect(model.isFirstStep)
        #expect(!model.isLastStep)
        #expect(model.progressText == "1 of \(model.steps.count)")

        model.goBack()
        #expect(model.selectedIndex == 0)

        model.goForward()
        #expect(model.selectedIndex == 1)

        model.select(model.steps.last!)
        #expect(model.isLastStep)
        #expect(model.progressText == "\(model.steps.count) of \(model.steps.count)")

        model.goForward()
        #expect(model.selectedIndex == model.steps.count - 1)

        model.goBack()
        #expect(model.selectedIndex == model.steps.count - 2)
    }

    @Test("default welcome steps cover the first-run product concepts")
    func defaultStepsCoverProductConcepts() {
        let ids = WelcomeFlowModel.defaultSteps.map(\.id)

        #expect(ids == ["canvas", "local", "dictation", "setup", "start"])
        #expect(WelcomeFlowModel.defaultSteps.contains { $0.body.localizedCaseInsensitiveContains("local") })
        #expect(WelcomeFlowModel.defaultSteps.contains { $0.body.localizedCaseInsensitiveContains("LLM") })
    }

    @Test("setup step levels with the user about model downloads")
    func setupStepMentionsDownloads() {
        let setup = WelcomeFlowModel.defaultSteps.first { $0.id == WelcomeFlowModel.setupStepID }
        #expect(setup != nil)
        // The audit's headline gap: onboarding must actually say a model
        // downloads, its rough size, and where the bytes come from.
        #expect(setup?.body.contains("460 MB") == true)
        #expect(setup?.primaryPoint.localizedCaseInsensitiveContains("Hugging Face") == true)
    }
}
