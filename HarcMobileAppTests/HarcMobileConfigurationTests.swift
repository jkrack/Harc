import XCTest
@testable import HarcMobile

final class HarcMobileConfigurationTests: XCTestCase {
    func testBackgroundModesContainOnlyAudio() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
                as? [String]
        )
        XCTAssertEqual(modes, ["audio"])
    }

    func testRequiredPrivacyDescriptionsArePresent() {
        for key in [
            "NSMicrophoneUsageDescription",
            "NSCameraUsageDescription",
            "NSLocalNetworkUsageDescription",
        ] {
            XCTAssertFalse(
                (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                    .isEmpty ?? true
            )
        }
    }
}
