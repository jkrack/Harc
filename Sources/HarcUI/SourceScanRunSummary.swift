import Foundation
import HarcContext

struct SourceScanRunSummary: Equatable {
    var discoveredCount: Int = 0
    var scannedCount: Int = 0
    var skippedCount: Int = 0
    var indexedCount: Int = 0
    var proposalCount: Int = 0
    var perSourceLimit: Int
    var excludeGlobs: [String] = LocalSourceScanner.defaultExcludeGlobs

    static func limitedBatch<T>(_ documents: [T], limit: Int) -> (batch: [T], skippedCount: Int) {
        let normalizedLimit = max(1, limit)
        let batch = Array(documents.prefix(normalizedLimit))
        return (batch, max(0, documents.count - batch.count))
    }

    var statusText: String {
        let proposalLabel = proposalCount == 1 ? "proposal" : "proposals"
        let indexedText = indexedCount > 0
            ? ", indexed \(indexedCount)"
            : ""
        let skippedText = skippedCount > 0
            ? " Skipped \(skippedCount) over the \(perSourceLimit)-document per-source limit; raise the limit in Library settings or connect a narrower folder."
            : " Limit: \(perSourceLimit) documents per source."
        let exclusionsText = excludeGlobs.isEmpty
            ? ""
            : " Excluding generated/vendor folders: \(excludeGlobs.joined(separator: ", "))."

        return "Found \(discoveredCount), scanned \(scannedCount), skipped \(skippedCount)\(indexedText). Created \(proposalCount) review \(proposalLabel).\(skippedText)\(exclusionsText)"
    }
}
