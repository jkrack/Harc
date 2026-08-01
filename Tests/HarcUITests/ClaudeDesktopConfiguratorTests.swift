import Testing
import Foundation
@testable import HarcUI

@Suite("ClaudeDesktopConfigurator")
struct ClaudeDesktopConfiguratorTests {

    private func makeConfig(existing: String? = nil) throws -> ClaudeDesktopConfigurator {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-tests-\(UUID().uuidString)/Claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude_desktop_config.json")
        if let existing {
            try existing.data(using: .utf8)!.write(to: url)
        }
        return ClaudeDesktopConfigurator(configURL: url)
    }

    @Test("install creates a fresh config when Desktop has never written one")
    func freshInstall() throws {
        let config = try makeConfig()
        #expect(config.status(expectedCommand: "/x/harc-mcp") == .notConfigured)

        try config.install(command: "/x/harc-mcp")
        #expect(config.status(expectedCommand: "/x/harc-mcp") == .configured)

        let written = try String(contentsOf: config.configURL, encoding: .utf8)
        #expect(written.contains("\"harc\""))
        #expect(written.contains("/x/harc-mcp"))
    }

    @Test("install merges into an existing config, preserving other keys and servers")
    func mergePreserves() throws {
        let config = try makeConfig(existing: """
            {
              "globalShortcut": "Cmd+Space",
              "mcpServers": {
                "other-tool": { "command": "/usr/local/bin/other", "args": ["--x"] }
              }
            }
            """)
        try config.install(command: "/x/harc-mcp")

        let data = try Data(contentsOf: config.configURL)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(root["globalShortcut"] as? String == "Cmd+Space")
        let servers = root["mcpServers"] as! [String: Any]
        #expect((servers["other-tool"] as! [String: Any])["command"] as? String == "/usr/local/bin/other")
        #expect((servers["harc"] as! [String: Any])["command"] as? String == "/x/harc-mcp")

        // The original was backed up before the first byte changed.
        let backup = config.configURL.appendingPathExtension("bak")
        let backedUp = try String(contentsOf: backup, encoding: .utf8)
        #expect(backedUp.contains("other-tool"))
        #expect(!backedUp.contains("harc-mcp"))
    }

    @Test("a stale path reads as configuredElsewhere and install repairs it")
    func stalePathRepair() throws {
        let config = try makeConfig(existing: """
            { "mcpServers": { "harc": { "command": "/old/Harc.app/Contents/MacOS/harc-mcp" } } }
            """)
        #expect(config.status(expectedCommand: "/new/harc-mcp")
            == .configuredElsewhere(currentCommand: "/old/Harc.app/Contents/MacOS/harc-mcp"))

        try config.install(command: "/new/harc-mcp")
        #expect(config.status(expectedCommand: "/new/harc-mcp") == .configured)
    }

    @Test("missing Claude directory reads as desktopNotFound")
    func missingDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-tests-\(UUID().uuidString)/Claude/claude_desktop_config.json")
        let config = ClaudeDesktopConfigurator(configURL: url)
        #expect(config.status(expectedCommand: "/x") == .desktopNotFound)
    }

    @Test("a corrupt config is backed up and replaced, not crashed on")
    func corruptConfig() throws {
        let config = try makeConfig(existing: "{ not json !!")
        #expect(config.status(expectedCommand: "/x/harc-mcp") == .notConfigured)

        try config.install(command: "/x/harc-mcp")
        #expect(config.status(expectedCommand: "/x/harc-mcp") == .configured)

        let backup = try String(
            contentsOf: config.configURL.appendingPathExtension("bak"), encoding: .utf8
        )
        #expect(backup.contains("not json"))
    }
}
