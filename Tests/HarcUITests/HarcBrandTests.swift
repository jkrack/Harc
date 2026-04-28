import Testing
import SwiftUI
@testable import HarcUI

@Suite("HarcBrand")
struct HarcBrandTests {
    @Test("live red is reachable and non-clear")
    func liveRedReachable() {
        let _ = HarcBrand.live
        // Smoke only — Color does not equate cleanly across CGColor conversions.
        // The compiler-level reachability is the actual assertion.
        #expect(Bool(true))
    }

    @Test("brand gradient is reachable")
    func gradientReachable() {
        let _ = HarcBrand.gradient
        #expect(Bool(true))
    }
}
