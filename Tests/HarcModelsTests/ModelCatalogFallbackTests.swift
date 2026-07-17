import XCTest
@testable import HarcModels

final class ModelCatalogFallbackTests: XCTestCase {

    func test_fallback_picksHighestInstalledTier_whenActiveRemoved() {
        // User has Standard + Quality installed, removes Quality.
        // Fallback should pick Standard (the only one left).
        let installed: Set<String> = ["gemma-4-e2b-it-4bit"]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-e4b-it-4bit"
        )
        XCTAssertEqual(id, "gemma-4-e2b-it-4bit")
    }

    func test_fallback_picksMaxOverStandard_whenBothInstalled() {
        // User removes Quality; Max + Standard remain. Should prefer Max.
        let installed: Set<String> = [
            "gemma-4-e2b-it-4bit",
            "gemma-4-26b-a4b-it-4bit",
        ]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-e4b-it-4bit"
        )
        XCTAssertEqual(id, "gemma-4-26b-a4b-it-4bit")
    }

    func test_fallback_picksProOverQuality_whenBothInstalled() {
        // User removes Max; Pro + Quality remain. Should prefer Pro.
        let installed: Set<String> = [
            "gemma-4-e4b-it-4bit",
            "gemma-4-12b-4bit",
        ]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-26b-a4b-it-4bit"
        )
        XCTAssertEqual(id, "gemma-4-12b-4bit")
    }

    func test_fallback_picksUltraOverMax_whenBothInstalled() {
        // User removes Quality; Ultra + Max remain. Should prefer Ultra.
        let installed: Set<String> = [
            "gemma-4-26b-a4b-it-4bit",
            "gemma-4-31b-it-4bit",
        ]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-e4b-it-4bit"
        )
        XCTAssertEqual(id, "gemma-4-31b-it-4bit")
    }

    func test_fallback_returnsDefault_whenNothingElseInstalled() {
        // User removes their only installed model. Fallback to the default —
        // even though it isn't installed, the UI will then prompt to download.
        let id = ModelCatalog.fallbackSummarizerID(
            installed: [],
            excluding: "gemma-4-26b-a4b-it-4bit"
        )
        XCTAssertEqual(id, ModelCatalog.defaultSummarizerID)
    }

    func test_fallback_excludesTheRemovedModel_evenIfStillInInstalledSet() {
        // Defensive: if the caller hasn't removed the model from `installed`
        // yet (race), the helper must still skip it.
        let installed: Set<String> = [
            "gemma-4-e2b-it-4bit",
            "gemma-4-26b-a4b-it-4bit",
        ]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-26b-a4b-it-4bit"
        )
        XCTAssertEqual(id, "gemma-4-e2b-it-4bit")
    }

    func test_fallback_ignoresEmbeddersAndUnknownIDs() {
        // The embedder is a different task; if it sneaks into `installed`,
        // it must not be picked as a summarizer fallback.
        let installed: Set<String> = ["bge-small-en-v1.5", "not-a-real-id"]
        let id = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: "gemma-4-e2b-it-4bit"
        )
        XCTAssertEqual(id, ModelCatalog.defaultSummarizerID)
    }

    func test_defaultSummarizerID_matchesPreferencesDefault() {
        // The HarcPreferences default summarizer is "gemma-4-e2b-it-4bit"
        // (see HarcPreferences.swift). Drift here would mean the fallback
        // points at a different model than the user's first-run default.
        XCTAssertEqual(ModelCatalog.defaultSummarizerID, "gemma-4-e2b-it-4bit")
    }
}
