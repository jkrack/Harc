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

        #expect(ids == ["canvas", "local", "dictation", "start"])
        #expect(WelcomeFlowModel.defaultSteps.contains { $0.body.localizedCaseInsensitiveContains("local") })
        #expect(WelcomeFlowModel.defaultSteps.contains { $0.body.localizedCaseInsensitiveContains("LLM") })
    }
}
