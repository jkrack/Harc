import Foundation
import Testing
@testable import HarcPresenceUI

@Suite("Harc fluid presence motion")
struct HarcPresenceFluidMotionTests {
    @Test("Fluid radii remain bounded across the audio range")
    func shapeRadiusBounds() {
        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            for index in 0 ..< HarcFluidPresenceMath.pointCount {
                let angle = Double(index)
                    / Double(HarcFluidPresenceMath.pointCount) * (.pi * 2)
                let radius = HarcFluidPresenceMath.radius(
                    angle: angle,
                    time: 123.456,
                    morph: 1,
                    level: level,
                    reduceMotion: false
                )
                #expect(radius >= 70)
                #expect(radius <= 130)
            }
        }
    }

    @Test("Audio smoothing attacks faster than it releases and converges")
    func asymmetricAudioSmoothing() {
        var smoother = HarcFluidAudioSmoother()
        smoother.step(rawLevel: 1, deltaTime: 1 / 60)
        let attackDelta = smoother.level
        #expect(abs(attackDelta - 0.35) < 0.000_001)

        let beforeRelease = smoother.level
        smoother.step(rawLevel: 0, deltaTime: 1 / 60)
        let releaseDelta = beforeRelease - smoother.level
        #expect(attackDelta > releaseDelta)
        #expect(abs(releaseDelta - (beforeRelease * 0.06)) < 0.000_001)

        for _ in 0 ..< 180 {
            smoother.step(rawLevel: 1, deltaTime: 1 / 60)
        }
        #expect(smoother.level > 0.999)
        for _ in 0 ..< 300 {
            smoother.step(rawLevel: 0, deltaTime: 1 / 60)
        }
        #expect(smoother.level < 0.001)
    }

    @Test("Reduce Motion produces a circle with no audio deformation")
    func reduceMotionHasNoDeformation() {
        let radii = (0 ..< HarcFluidPresenceMath.pointCount).map { index in
            HarcFluidPresenceMath.radius(
                angle: Double(index)
                    / Double(HarcFluidPresenceMath.pointCount) * (.pi * 2),
                time: 42,
                morph: 1,
                level: 1,
                reduceMotion: true
            )
        }
        #expect(Set(radii).count == 1)
        #expect(radii.first == HarcFluidPresenceMath.referenceRadius)
    }

    @Test("Classic remains the default and preserves its radius equation")
    @MainActor
    func classicOutputIsUnchanged() {
        let blob = HarcPresenceBlob(state: .recording)
        #expect(blob.motion == .classic)

        let angle = 0.73
        let phase = 1.21
        let activity = 0.64
        let expected = 100 * (
            1
                + (sin((angle * 3) + phase) * 0.045)
                + (sin((angle * 5) - (phase * 1.31)) * 0.025)
                + activity * (
                    0.060
                        + (sin((angle * 4) + (phase * 1.7)) * 0.035)
                )
        )
        #expect(abs(HarcClassicPresenceMath.radius(
            baseRadius: 100,
            angle: angle,
            phase: phase,
            activity: activity
        ) - expected) < 0.000_001)
    }
}
