import XCTest
@testable import HarcModels

final class ModelInstallStateTests: XCTestCase {

    func test_isInstalled_onlyTrueForInstalled() {
        XCTAssertTrue(ModelInstallState.installed.isInstalled)
        XCTAssertFalse(ModelInstallState.absent.isInstalled)
        XCTAssertFalse(ModelInstallState.downloading(progress: 0.5).isInstalled)
        XCTAssertFalse(ModelInstallState.verifying.isInstalled)
        XCTAssertFalse(ModelInstallState.failed(reason: "x").isInstalled)
    }

    func test_isBusy_trueForDownloadingAndVerifying() {
        XCTAssertTrue(ModelInstallState.downloading(progress: 0.25).isBusy)
        XCTAssertTrue(ModelInstallState.verifying.isBusy)
        XCTAssertFalse(ModelInstallState.absent.isBusy)
        XCTAssertFalse(ModelInstallState.installed.isBusy)
        XCTAssertFalse(ModelInstallState.failed(reason: "x").isBusy)
    }

    func test_equality_distinguishesProgressTicks() {
        XCTAssertNotEqual(
            ModelInstallState.downloading(progress: 0.25),
            ModelInstallState.downloading(progress: 0.26)
        )
    }
}
