import Foundation
import Testing
@testable import HarcCore

@Suite("Version")
struct VersionTests {
    @Test("fallback is SemVer")
    func fallbackIsSemVer() {
        let parts = HarcVersion.fallbackVersion.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    /// The check that was missing. `HarcVersion.current` used to be a literal
    /// maintained by hand next to `project.yml`'s `MARKETING_VERSION`, and the
    /// only tests over it compared it to itself — so it sat five minor
    /// releases stale (`0.2.17` vs `0.7.3`) while the menu-bar panel, the
    /// `harc-stt` CLI and the daemon's `status` response all reported it.
    ///
    /// `current` now reads the bundle, so the literal survives only as the
    /// no-bundle fallback. This pins that fallback to the real version.
    @Test("fallback matches project.yml MARKETING_VERSION")
    func fallbackMatchesProjectFile() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HarcCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let projectFile = repoRoot.appendingPathComponent("project.yml")
        let yaml = try String(contentsOf: projectFile, encoding: .utf8)

        let declared = yaml
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("MARKETING_VERSION:") else { return nil }
                return trimmed
                    .replacingOccurrences(of: "MARKETING_VERSION:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .first

        let version = try #require(declared, "project.yml has no MARKETING_VERSION")
        #expect(
            HarcVersion.fallbackVersion == version,
            "HarcVersion.fallbackVersion (\(HarcVersion.fallbackVersion)) has drifted from project.yml (\(version))"
        )
    }
}
