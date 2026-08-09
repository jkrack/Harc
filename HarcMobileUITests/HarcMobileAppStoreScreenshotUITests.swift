import XCTest

@MainActor
final class HarcMobileAppStoreScreenshotUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    #if targetEnvironment(simulator)
      guard
        ProcessInfo.processInfo.environment[
          "SIMULATOR_MODEL_IDENTIFIER"
        ] == "iPhone16,2"
      else {
        throw XCTSkip(
          "App Store capture requires an iPhone 15 Pro Max simulator."
        )
      }
    #else
      throw XCTSkip(
        "App Store attachments are captured on the release simulator."
      )
    #endif
  }

  func testCaptureTruthfulReleaseSurfaces() throws {
    let app = XCUIApplication()
    app.launch()

    let ready = app.staticTexts["Ready to record locally"]
    XCTAssertTrue(ready.waitForExistence(timeout: 15))
    keepScreenshot(named: "01-record")

    let libraryTab = app.tabBars.buttons["Library"]
    XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
    libraryTab.tap()
    let openSample = app.buttons[
      "harc.mobile.reviewSample.open.toolbar"
    ]
    XCTAssertTrue(openSample.waitForExistence(timeout: 10))
    openSample.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "harc.mobile.reviewSample.root"
      ].waitForExistence(timeout: 10)
    )
    keepScreenshot(named: "03-review-sample")

    let closeSample = app.buttons["Close Review Sample"]
    XCTAssertTrue(closeSample.waitForExistence(timeout: 5))
    closeSample.tap()

    let hostTab = app.tabBars.buttons["Host"]
    XCTAssertTrue(hostTab.waitForExistence(timeout: 5))
    hostTab.tap()
    let privacy = app.buttons["Privacy & Data"]
    XCTAssertTrue(privacy.waitForExistence(timeout: 10))
    privacy.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["harc.mobile.privacy"]
        .waitForExistence(timeout: 10)
    )
    keepScreenshot(named: "05-privacy-host")
  }

  private func keepScreenshot(named name: String) {
    let attachment = XCTAttachment(
      screenshot: XCUIScreen.main.screenshot()
    )
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
