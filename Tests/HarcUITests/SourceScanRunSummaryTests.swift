import Testing
@testable import HarcUI

struct SourceScanRunSummaryTests {
    @Test("limitedBatch scans up to the configured limit and reports skipped documents")
    func limitedBatchReportsSkippedDocuments() {
        let documents = Array(0..<45)

        let limited = SourceScanRunSummary.limitedBatch(documents, limit: 40)

        #expect(limited.batch == Array(0..<40))
        #expect(limited.skippedCount == 5)
    }

    @Test("limitedBatch treats invalid limits as one document")
    func limitedBatchNormalizesInvalidLimit() {
        let limited = SourceScanRunSummary.limitedBatch([1, 2, 3], limit: 0)

        #expect(limited.batch == [1])
        #expect(limited.skippedCount == 2)
    }

    @Test("status text includes discovered scanned skipped indexed limit and exclusions")
    func statusTextIncludesScanDetails() {
        let summary = SourceScanRunSummary(
            discoveredCount: 45,
            scannedCount: 40,
            skippedCount: 5,
            indexedCount: 40,
            proposalCount: 3,
            perSourceLimit: 40,
            excludeGlobs: ["node_modules/**", ".build/**"]
        )

        let text = summary.statusText

        #expect(text.contains("Found 45, scanned 40, skipped 5, indexed 40"))
        #expect(text.contains("Created 3 review proposals"))
        #expect(text.contains("40-document per-source limit"))
        #expect(text.contains("raise the limit in Library settings"))
        #expect(text.contains("node_modules/**"))
        #expect(text.contains(".build/**"))
    }
}
