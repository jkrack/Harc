import XCTest
@testable import HarcModels

final class ModelCatalogTests: XCTestCase {

    func test_catalog_hasNoDuplicateIDs() {
        let ids = ModelCatalog.v1.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate model ids in ModelCatalog.v1")
    }

    func test_everyURLIsHTTPS() {
        for d in ModelCatalog.v1 {
            for f in d.files {
                XCTAssertEqual(f.url.scheme, "https",
                    "Non-https URL in descriptor \(d.id): \(f.url)")
            }
        }
    }

    func test_sha256_is_64HexOrEmpty() {
        for d in ModelCatalog.v1 {
            for f in d.files {
                if !f.sha256.isEmpty {
                    XCTAssertEqual(f.sha256.count, 64, "sha256 in \(d.id)/\(f.path) not 64 hex chars")
                    XCTAssertTrue(f.sha256.allSatisfy { "0123456789abcdefABCDEF".contains($0) },
                        "sha256 in \(d.id)/\(f.path) contains non-hex chars")
                }
            }
        }
    }

    func test_totalBytes_equalsSumOfFileBytes() {
        for d in ModelCatalog.v1 {
            let sum = d.files.map(\.bytes).reduce(0, +)
            XCTAssertEqual(d.totalBytes, sum, "totalBytes mismatch for \(d.id)")
        }
    }

    func test_descriptor_lookupByID() {
        XCTAssertNotNil(ModelCatalog.descriptor(for: "gemma-4-e2b-it-4bit"))
        XCTAssertNil(ModelCatalog.descriptor(for: "does-not-exist"))
    }

    func test_descriptors_byTask_summarizersOrderedStdQualityMax() {
        let summarizers = ModelCatalog.descriptors(for: .summarizer)
        XCTAssertGreaterThanOrEqual(summarizers.count, 3)
        XCTAssertEqual(summarizers[0].tier, .standard)
        XCTAssertEqual(summarizers[1].tier, .quality)
        XCTAssertEqual(summarizers[2].tier, .max)
    }

    func test_descriptors_embedderIsSingleton() {
        let embedders = ModelCatalog.descriptors(for: .textEmbedder)
        XCTAssertEqual(embedders.count, 1)
        XCTAssertEqual(embedders[0].tier, .singleton)
    }
}
