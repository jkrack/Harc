import Testing
import SwiftUI
@testable import HarcUI

@Suite("Design tokens smoke")
struct DesignTokensSmokeTests {
    @Test("spacing tokens are monotonic")
    func spacingMonotonic() {
        #expect(HarcDesign.Space.xxs < HarcDesign.Space.xs)
        #expect(HarcDesign.Space.xs < HarcDesign.Space.sm)
        #expect(HarcDesign.Space.sm < HarcDesign.Space.md)
        #expect(HarcDesign.Space.md < HarcDesign.Space.lg)
        #expect(HarcDesign.Space.lg < HarcDesign.Space.xl)
    }

    @Test("corner radii are monotonic")
    func radiusMonotonic() {
        #expect(HarcDesign.Radius.sm < HarcDesign.Radius.md)
        #expect(HarcDesign.Radius.md < HarcDesign.Radius.lg)
        #expect(HarcDesign.Radius.lg < HarcDesign.Radius.xl)
        #expect(HarcDesign.Radius.xl < HarcDesign.Radius.full)
    }
}
