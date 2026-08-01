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
    @State private var desktopStatus: ClaudeDesktopConfigurator.Status = .desktopNotFound
    @State private var desktopJustAdded = false
    @State private var desktopError: String?

    private let desktopConfig = ClaudeDesktopConfigurator()

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
            // Claude Desktop first — it has no command line, so this is the
            // one host where "here's a terminal command" goes nowhere. Harc
            // writes the entry into Desktop's own config instead.
            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("Claude Desktop")
                    .font(.harcBody)
                desktopRow
                Text("Claude Desktop reads its configuration at launch — restart it after adding, then Harc's tools appear in the search-and-tools menu.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)

            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                Text("Claude Code")
                    .font(.harcBody)
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
                        copyToPasteboard(mcpAddCommand)
                        flashCopied($didCopyCommand)
                    }
                    .controlSize(.small)
                }
                Text("Run in a terminal. \u{201C}--scope user\u{201D} registers Harc for every project, not just the current directory. Verify with \u{201C}claude mcp get harc\u{201D}; a session already running when you add it needs a restart to discover the tools.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)

            VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                HStack(spacing: HarcSpacing.sm) {
                    Text("Other MCP clients")
                        .font(.harcBody)
                    Button(didCopyJSON ? "Copied" : "Copy JSON") {
                        copyToPasteboard(mcpServersJSON)
                        flashCopied($didCopyJSON)
                    }
                    .controlSize(.small)
                    .help("A complete mcpServers config block — valid as a project .mcp.json or merged into any MCP client's config")
                }
                Text("Copies a complete \u{201C}mcpServers\u{201D} block that works verbatim as a project .mcp.json and merges into any stdio MCP client's configuration.")
                    .font(.harcCaption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, HarcSpacing.xs)
        } header: {
            Text("Connect an Agent (MCP)")
        } footer: {
            Text("If your recordings folder lives in Documents, macOS may ask the agent's app — not Harc — for Documents access the first time an agent writes; grant it there. If it's denied, the database write still succeeds and the Markdown file catches up the next time Harc edits that recording.")
                .font(.harcLabel)
                .foregroundStyle(Color.secondary)
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

    // MARK: - Claude Desktop

    @ViewBuilder
    private var desktopRow: some View {
        HStack(spacing: HarcSpacing.sm) {
            switch desktopStatus {
            case .desktopNotFound:
                Text("Claude Desktop doesn't appear to be installed on this Mac.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            case .notConfigured:
                Button("Add to Claude Desktop") { installIntoDesktop() }
            case .configuredElsewhere:
                Button("Update Path") { installIntoDesktop() }
                Text("Connected, but pointing at an older copy of Harc.")
                    .font(.harcLabel)
                    .foregroundStyle(Color.secondary)
            case .configured:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.harc(.ready))
                Text(desktopJustAdded
                    ? "Added — restart Claude Desktop to pick it up."
                    : "Connected.")
                    .font(.harcLabel)
            }
            Spacer(minLength: 0)
        }
        .task { desktopStatus = desktopConfig.status(expectedCommand: mcpBinaryPath) }

        if let desktopError {
            Label(desktopError, systemImage: "exclamationmark.triangle.fill")
                .font(.harcCaption)
                .foregroundStyle(Color.harc(.attention))
        }
    }

    /// Merge the harc entry into Claude Desktop's config (backed up first,
    /// everything else in the file preserved).
    private func installIntoDesktop() {
        do {
            try desktopConfig.install(command: mcpBinaryPath)
            desktopJustAdded = true
            desktopError = nil
        } catch {
            desktopError = "Couldn't update Claude Desktop's config: \(error.localizedDescription)"
        }
        desktopStatus = desktopConfig.status(expectedCommand: mcpBinaryPath)
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func flashCopied(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            flag.wrappedValue = false
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

    /// Resolved from the running bundle so dev builds register their own binary.
    private var mcpBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/harc-mcp").path
    }

    private var mcpAddCommand: String {
        "claude mcp add --scope user harc -- \(mcpBinaryPath)"
    }

    /// A complete `mcpServers` block — valid verbatim as a project
    /// `.mcp.json`, and the same shape every stdio MCP client's config takes.
    private var mcpServersJSON: String {
        """
        {
          "mcpServers": {
            "harc": {
              "command": "\(mcpBinaryPath)"
            }
          }
        }
        """
    }
}
