import Testing
import Foundation
@testable import HarcUI
import HarcCore

@MainActor
struct HarcPreferencesTests {
    @Test("addEntry persists in memory and roundtrips through UserDefaults")
    func addEntryRoundTrip() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        let startCount = prefs.vocabulary.entries.count
        prefs.addEntry(from: marker, to: "Parakeet")
        #expect(prefs.vocabulary.entries.count == startCount + 1)
        #expect(prefs.vocabulary.entries.last?.from == marker)
        #expect(prefs.vocabulary.entries.last?.to == "Parakeet")

        let reloaded = HarcPreferences()
        #expect(reloaded.vocabulary.entries.contains(where: { $0.from == marker }))

        if let id = prefs.vocabulary.entries.first(where: { $0.from == marker })?.id {
            prefs.deleteEntries(ids: [id])
        }
    }

    @Test("toggleEntry flips enabled flag")
    func toggleEntry() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        prefs.addEntry(from: marker, to: "Bar")
        guard let id = prefs.vocabulary.entries.first(where: { $0.from == marker })?.id else {
            Issue.record("added entry not found")
            return
        }
        let before = prefs.vocabulary.entries.first(where: { $0.id == id })?.enabled ?? false
        prefs.toggleEntry(id: id)
        let after = prefs.vocabulary.entries.first(where: { $0.id == id })?.enabled ?? false
        #expect(after != before)
        prefs.deleteEntries(ids: [id])
    }

    @Test("deleteEntries removes by id")
    func deleteEntriesById() {
        let prefs = HarcPreferences()
        let marker = "HarcTest_\(UUID().uuidString)"
        prefs.addEntry(from: marker, to: "X")
        let id = prefs.vocabulary.entries.first(where: { $0.from == marker })!.id
        prefs.deleteEntries(ids: [id])
        #expect(!prefs.vocabulary.entries.contains(where: { $0.id == id }))
    }

    @Test("autoPasteEnabled defaults to true when UserDefaults has no key")
    func autoPasteEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.autoPasteEnabled == true)
    }

    @Test("autoPasteEnabled persists and round-trips through UserDefaults")
    func autoPasteEnabledPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
        let prefs = HarcPreferences()
        prefs.autoPasteEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.autoPasteEnabled == false)
        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.autoPasteEnabled")
    }

    @Test("pasteDenyListBundleIDs defaults to the seed list")
    func pasteDenyListDefaultsToSeedList() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.pasteDenyListBundleIDs")
        let prefs = HarcPreferences()
        #expect(prefs.pasteDenyListBundleIDs == PasteDenyList.defaultBundleIDs)
        defaults.removeObject(forKey: "harc.pasteDenyListBundleIDs")
    }

    @Test("pasteDenyListBundleIDs persists custom entries")
    func pasteDenyListPersistsCustomEntries() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.pasteDenyListBundleIDs")
        let prefs = HarcPreferences()
        prefs.addPasteDenyListBundleID("com.example.private")
        let reloaded = HarcPreferences()
        #expect(reloaded.pasteDenyListBundleIDs.contains("com.example.private"))
        defaults.removeObject(forKey: "harc.pasteDenyListBundleIDs")
    }

    @Test("paste deny list removes user entries but preserves locked entries")
    func pasteDenyListRemovalPreservesLockedEntries() {
        let defaults = UserDefaults.standard
        defaults.set([
            "com.example.private",
            "com.apple.loginwindow",
        ], forKey: "harc.pasteDenyListBundleIDs")

        let prefs = HarcPreferences()
        prefs.removePasteDenyListBundleID("com.example.private")
        prefs.removePasteDenyListBundleID("com.apple.loginwindow")

        #expect(!prefs.pasteDenyListBundleIDs.contains("com.example.private"))
        #expect(prefs.pasteDenyListBundleIDs.contains("com.apple.loginwindow"))
        defaults.removeObject(forKey: "harc.pasteDenyListBundleIDs")
    }

    @Test("vadEnabled defaults to true when UserDefaults has no key")
    func vadEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.vadEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.vadEnabled == true)
    }

    @Test("vadEnabled persists and round-trips through UserDefaults")
    func vadEnabledPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.vadEnabled")
        let prefs = HarcPreferences()
        prefs.vadEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.vadEnabled == false)
        defaults.removeObject(forKey: "harc.vadEnabled")
    }

    @Test("speakerReIDEnabled defaults to true when UserDefaults has no key")
    func speakerReIDEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.speakerReIDEnabled")
        let prefs = HarcPreferences()
        #expect(prefs.speakerReIDEnabled == true)
    }

    @Test("speakerReIDEnabled persists false when explicitly set")
    func speakerReIDEnabledPreservesUserFalse() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.speakerReIDEnabled")
        let prefs = HarcPreferences()
        prefs.speakerReIDEnabled = false
        let reloaded = HarcPreferences()
        #expect(reloaded.speakerReIDEnabled == false)
        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.speakerReIDEnabled")
    }

    @Test("speakerReIDAutoApply defaults to false when UserDefaults has no key")
    func speakerReIDAutoApplyDefaultFalse() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.speakerReIDAutoApply")
        let prefs = HarcPreferences()
        #expect(prefs.speakerReIDAutoApply == false)
    }

    @Test("speakerReIDAutoApply persists when explicitly set to true")
    func speakerReIDAutoApplyPreservesUserTrue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.speakerReIDAutoApply")
        let prefs = HarcPreferences()
        prefs.speakerReIDAutoApply = true
        let reloaded = HarcPreferences()
        #expect(reloaded.speakerReIDAutoApply == true)
        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.speakerReIDAutoApply")
    }

    @Test("sourceScanLimit defaults to forty documents")
    func sourceScanLimitDefaultsToForty() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.sourceScanLimit")
        let prefs = HarcPreferences()
        #expect(prefs.sourceScanLimit == 40)
        defaults.removeObject(forKey: "harc.sourceScanLimit")
    }

    @Test("sourceScanLimit persists and clamps to the supported range")
    func sourceScanLimitPersistsAndClamps() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.sourceScanLimit")

        let prefs = HarcPreferences()
        prefs.sourceScanLimit = 80
        #expect(HarcPreferences().sourceScanLimit == 80)

        prefs.sourceScanLimit = 1
        #expect(prefs.sourceScanLimit == HarcPreferences.sourceScanLimitRange.lowerBound)
        #expect(HarcPreferences().sourceScanLimit == HarcPreferences.sourceScanLimitRange.lowerBound)

        prefs.sourceScanLimit = 999
        #expect(prefs.sourceScanLimit == HarcPreferences.sourceScanLimitRange.upperBound)
        #expect(HarcPreferences().sourceScanLimit == HarcPreferences.sourceScanLimitRange.upperBound)

        defaults.removeObject(forKey: "harc.sourceScanLimit")
    }

    @Test("welcome flow defaults incomplete and persists completion")
    func welcomeFlowCompletionPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.welcomeFlowCompleted")

        let prefs = HarcPreferences()
        #expect(prefs.welcomeFlowCompleted == false)

        prefs.completeWelcomeFlow()
        #expect(HarcPreferences().welcomeFlowCompleted == true)

        defaults.removeObject(forKey: "harc.welcomeFlowCompleted")
    }

    @Test("model performance mode defaults to balanced and persists")
    func modelPerformanceModePersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.modelPerformanceMode")

        let prefs = HarcPreferences()
        #expect(prefs.modelPerformanceMode == .balanced)
        #expect(prefs.modelPerformanceMode.summarizerIdleUnloadDelay == 10 * 60)
        #expect(prefs.modelPerformanceMode.embedderIdleUnloadDelay == 30 * 60)

        prefs.modelPerformanceMode = .lowMemory
        #expect(HarcPreferences().modelPerformanceMode == .lowMemory)
        #expect(HarcPreferences.ModelPerformanceMode.lowMemory.summarizerIdleUnloadDelay == 0)

        defaults.removeObject(forKey: "harc.modelPerformanceMode")
    }

    @Test("markdown formatting ribbon defaults on and persists")
    func markdownFormattingRibbonPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.markdownFormattingRibbonEnabled")

        let prefs = HarcPreferences()
        #expect(prefs.markdownFormattingRibbonEnabled == true)

        prefs.markdownFormattingRibbonEnabled = false
        #expect(HarcPreferences().markdownFormattingRibbonEnabled == false)

        defaults.removeObject(forKey: "harc.markdownFormattingRibbonEnabled")
    }
}
