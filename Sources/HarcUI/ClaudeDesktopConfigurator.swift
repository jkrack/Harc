import Foundation

/// One-click registration of harc-mcp in Claude Desktop's config file.
///
/// Claude Desktop has no command line — `claude mcp add` is a Claude Code
/// command, and telling Desktop users to run it goes nowhere. Desktop reads
/// `~/Library/Application Support/Claude/claude_desktop_config.json`, so
/// Harc (unsandboxed) edits it directly: read, merge `mcpServers.harc`,
/// back up the original, write atomically. Every other key in the file is
/// preserved untouched.
struct ClaudeDesktopConfigurator {
    let configURL: URL

    static let serverName = "harc"

    init(configURL: URL? = nil) {
        self.configURL = configURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    enum Status: Equatable {
        /// No Claude Desktop config directory — Desktop has likely never run.
        case desktopNotFound
        /// Config exists (or can be created) but has no harc entry.
        case notConfigured
        /// harc entry present and pointing at `expectedCommand`.
        case configured
        /// harc entry present but pointing somewhere else (old install path,
        /// moved app). Offer an update.
        case configuredElsewhere(currentCommand: String)
    }

    /// Where the entry should point — resolved by the caller from the
    /// running bundle so dev builds register their own binary.
    func status(expectedCommand: String) -> Status {
        let dir = configURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return .desktopNotFound
        }
        guard let root = try? readConfig(),
              let servers = root["mcpServers"] as? [String: Any],
              let harc = servers[Self.serverName] as? [String: Any],
              let command = harc["command"] as? String else {
            return .notConfigured
        }
        return command == expectedCommand
            ? .configured
            : .configuredElsewhere(currentCommand: command)
    }

    /// Merge (or update) the harc entry. Creates the config file if Desktop
    /// hasn't written one yet but its directory exists. Backs up an existing
    /// file to `<name>.bak` before the first byte changes.
    func install(command: String) throws {
        var root = (try? readConfig()) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = ["command": command]
        root["mcpServers"] = servers

        let fm = FileManager.default
        if fm.fileExists(atPath: configURL.path) {
            let backup = configURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: configURL, to: backup)
        } else {
            try fm.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: .atomic)
    }

    private func readConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return root
    }
}
