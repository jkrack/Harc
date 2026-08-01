import SwiftUI
import AppKit

/// The Agents pane: connecting MCP clients (Claude Desktop, Claude Code,
/// or any MCP host) to the bundled harc-mcp bridge, and the plain-language
/// contract for what a connected agent can and cannot touch.
///
/// Promoted out of the About pane: connectivity is a capability the user
/// configures and reasons about, not install-time reference material.
public struct AgentsSettingsView: View {
    @State private var didCopyCommand = false
    @State private var didCopyJSON = false

    public init() {}

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("Harc ships a small MCP server so AI agents you run can search your transcripts and enrich your notes. It talks directly to the library on this Mac and works while Harc is closed. It opens no network connections and holds no API keys — the agent brings its own model and account, at your choosing.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)
        } header: {
            Text("Agents")
        }

        Section {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("For Claude Code, run:")
                    .font(.harcLabel)

                HStack(spacing: HarcSpacing.sm) {
                    Text(mcpAddCommand)
                        .font(.harcMono)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, HarcSpacing.sm)
                        .padding(.vertical, HarcSpacing.xs)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    Button(didCopyCommand ? "Copied" : "Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(mcpAddCommand, forType: .string)
                        didCopyCommand = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopyCommand = false
                        }
                    }
                    .controlSize(.small)
                    // The same server as JSON — pastes cleanly into a
                    // project .mcp.json or claude_desktop_config.json
                    // without scope ambiguity.
                    Button(didCopyJSON ? "Copied" : "Copy JSON") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(mcpServerJSON, forType: .string)
                        didCopyJSON = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopyJSON = false
                        }
                    }
                    .controlSize(.small)
                    .help("The server entry as JSON, for .mcp.json or claude_desktop_config.json")
                }

                Text("\u{201C}--scope user\u{201D} registers Harc for every project, not just the current directory. Verify with \u{201C}claude mcp get harc\u{201D}; a session already running when you add it needs a restart to discover the tools. For Claude Desktop, add the same executable path under \u{201C}mcpServers\u{201D} in claude_desktop_config.json. Any MCP client that speaks stdio works.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("If your recordings folder lives in Documents, macOS may ask the agent's app — not Harc — for Documents access the first time an agent writes; grant it there. If it's denied, the database write still succeeds and the Markdown file catches up the next time Harc edits that recording.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)
        } header: {
            Text("Connect an Agent (MCP)")
        }

        Section {
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                capabilityRow(
                    symbol: "magnifyingglass",
                    title: "Search and read",
                    detail: "Hybrid search over transcripts, full recording detail, and recent lists."
                )
                capabilityRow(
                    symbol: "square.and.pencil",
                    title: "Write back, through the library",
                    detail: "Titles, tags, speaker names, and summaries — every write goes through the same database the app uses, so the Markdown files regenerate correctly."
                )
                capabilityRow(
                    symbol: "note.text.badge.plus",
                    title: "Append notes, never rewrite them",
                    detail: "Agent notes are append-only and stamped with the author and date. What you wrote stays yours."
                )
                capabilityRow(
                    symbol: "lock",
                    title: "Transcripts are read-only",
                    detail: "There is no tool that edits a transcript, by design."
                )
            }
            .padding(.vertical, HarcSpacing.xs)
        } header: {
            Text("What Agents Can Read and Write")
        } footer: {
            Text("Handing a transcript to a cloud model is your decision, made in the agent — Harc itself never sends audio or text anywhere.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
        }
    }

    private func capabilityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: HarcSpacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.harcBody)
                Text(detail)
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Resolved from the running bundle so dev builds show their real path.
    private var mcpAddCommand: String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/harc-mcp").path
        return "claude mcp add --scope user harc -- \(path)"
    }

    /// The server entry as JSON — the shape `.mcp.json` and
    /// `claude_desktop_config.json` both take under a server name.
    private var mcpServerJSON: String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/harc-mcp").path
        return """
        {
          "command": "\(path)"
        }
        """
    }
}
