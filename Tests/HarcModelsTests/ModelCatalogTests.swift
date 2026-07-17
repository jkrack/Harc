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

    func test_sha256_is_64Hex() {
        for d in ModelCatalog.v1 {
            for f in d.files {
                XCTAssertEqual(f.sha256.count, 64, "sha256 in \(d.id)/\(f.path) not 64 hex chars")
                XCTAssertTrue(f.sha256.allSatisfy { "0123456789abcdefABCDEF".contains($0) },
                    "sha256 in \(d.id)/\(f.path) contains non-hex chars")
            }
        }
    }

    func test_downloadableDescriptors_usePinnedRevisionsAndCompleteHashes() {
        for d in ModelCatalog.v1 where d.manifestVerified {
            XCTAssertNotEqual(d.revision, "main", "\(d.id) must pin an immutable revision")
            XCTAssertTrue(ModelManager.isDownloadManifestTrusted(d), "\(d.id) is marked verified but is not trusted")
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
        XCTAssertNotNil(ModelCatalog.descriptor(for: "gemma-4-12b-4bit"))
        XCTAssertNil(ModelCatalog.descriptor(for: "gemma-4-12b-it-4bit"))
        XCTAssertNil(ModelCatalog.descriptor(for: "does-not-exist"))
    }

    func test_descriptors_byTask_summarizersOrderedStdQualityProMaxUltra() {
        let summarizers = ModelCatalog.descriptors(for: .summarizer)
        XCTAssertGreaterThanOrEqual(summarizers.count, 5)
        XCTAssertEqual(summarizers[0].tier, .standard)
        XCTAssertEqual(summarizers[1].tier, .quality)
        XCTAssertEqual(summarizers[2].tier, .pro)
        XCTAssertEqual(summarizers[3].tier, .max)
        XCTAssertEqual(summarizers[4].tier, .ultra)
        XCTAssertEqual(summarizers.map(\.id), [
            "gemma-4-e2b-it-4bit",
            "gemma-4-e4b-it-4bit",
            "gemma-4-12b-4bit",
            "gemma-4-26b-a4b-it-4bit",
            "gemma-4-31b-it-4bit",
        ])
    }

    func test_ultraTier_ordersAboveMax_andBelowNoSingleton() {
        XCTAssertTrue(ModelTier.max < ModelTier.ultra)
        XCTAssertTrue(ModelTier.pro < ModelTier.ultra)
        XCTAssertTrue(ModelTier.singleton < ModelTier.ultra)
        XCTAssertEqual(ModelTier.ultra.rawValue, "ultra")
    }

    func test_gemma31B_entryIsSaneAndHonest() {
        guard let d = ModelCatalog.descriptor(for: "gemma-4-31b-it-4bit") else {
            return XCTFail("gemma-4-31b-it-4bit missing from catalog")
        }
        XCTAssertEqual(d.tier, .ultra)
        XCTAssertEqual(d.task, .summarizer)
        XCTAssertEqual(d.repoID, "mlx-community/gemma-4-31b-it-4bit")
        XCTAssertEqual(d.revision, "696d436c404745a59f30e4939a658162b0a9e57f")
        XCTAssertFalse(d.files.isEmpty)
        XCTAssertTrue(d.manifestVerified)
        // 4 shards + config/tokenizer sidecars, all URLs pinned to the revision.
        XCTAssertEqual(d.files.filter { $0.path.hasSuffix(".safetensors") }.count, 4)
        for f in d.files {
            XCTAssertTrue(f.url.absoluteString.contains(d.revision),
                "\(f.path) URL not pinned to revision")
        }
        // ~18.4 GB total — catch a fat-fingered manifest in either direction.
        XCTAssertGreaterThan(d.totalBytes, 18_000_000_000)
        XCTAssertLessThan(d.totalBytes, 19_000_000_000)
        // Heaviest model in the catalog: RAM floor must exceed Max's, and the
        // ask must stay sane.
        guard let maxTier = ModelCatalog.descriptor(for: "gemma-4-26b-a4b-it-4bit") else {
            return XCTFail("max-tier descriptor missing")
        }
        XCTAssertGreaterThanOrEqual(d.minRAMGB, maxTier.minRAMGB)
        XCTAssertGreaterThanOrEqual(d.recommendedRAMGB, d.minRAMGB)
        XCTAssertLessThanOrEqual(d.recommendedRAMGB, 64)
    }

    func test_atLeastOneSummarizerHasVerifiedManifest() {
        let summarizers = ModelCatalog.descriptors(for: .summarizer)
        XCTAssertTrue(summarizers.contains(where: { $0.manifestVerified }),
            "No summarizer has a verified manifest — at least one needs real URLs so downloads can run.")
    }

    func test_allSummarizersHaveVerifiedManifests() {
        for d in ModelCatalog.descriptors(for: .summarizer) {
            XCTAssertTrue(d.manifestVerified, "\(d.id) should be downloadable from Settings.")
        }
    }

    func test_verifiedEntriesDeclareNonZeroSize() {
        for d in ModelCatalog.v1 where d.manifestVerified {
            XCTAssertGreaterThan(d.totalBytes, 0,
                "Verified manifest for \(d.id) reports 0 total bytes")
            for f in d.files {
                XCTAssertGreaterThan(f.bytes, 0,
                    "Verified manifest \(d.id)/\(f.path) has 0 bytes")
            }
        }
    }
}
