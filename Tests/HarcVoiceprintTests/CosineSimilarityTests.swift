import XCTest
@testable import HarcVoiceprint

final class CosineSimilarityTests: XCTestCase {

    func test_identicalVectors_giveOne() {
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(CosineSimilarity.of(v, v), 1.0, accuracy: 1e-6)
    }

    func test_antipodalVectors_giveNegativeOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(CosineSimilarity.of(a, b), -1.0, accuracy: 1e-6)
    }

    func test_orthogonalVectors_giveZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(CosineSimilarity.of(a, b), 0.0, accuracy: 1e-6)
    }

    func test_unequalLengths_giveZero() {
        XCTAssertEqual(CosineSimilarity.of([1, 2, 3], [1, 2]), 0)
    }

    func test_emptyVectors_giveZero() {
        XCTAssertEqual(CosineSimilarity.of([], []), 0)
    }

    func test_zeroNorm_giveZero() {
        XCTAssertEqual(CosineSimilarity.of([0, 0, 0], [1, 2, 3]), 0)
    }

    func test_dotNormalizedIsCheaperEquivalent() {
        var a: [Float] = [3, 4, 0]
        var b: [Float] = [4, 3, 0]
        let generalized = CosineSimilarity.of(a, b)
        l2Normalize(&a)
        l2Normalize(&b)
        let fast = CosineSimilarity.dotNormalized(a, b)
        XCTAssertEqual(generalized, fast, accuracy: 1e-6)
    }

    func test_l2Normalize_unitLength() {
        var v: [Float] = [3, 4]
        l2Normalize(&v)
        let n = sqrtf(v[0] * v[0] + v[1] * v[1])
        XCTAssertEqual(n, 1.0, accuracy: 1e-6)
    }

    func test_l2Normalize_zeroVectorStaysZero() {
        var v: [Float] = [0, 0, 0]
        l2Normalize(&v)
        XCTAssertEqual(v, [0, 0, 0])
    }
}
