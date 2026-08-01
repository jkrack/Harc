import Foundation
import HarcCore
import HarcStore
import MCP

// harc-mcp — the agent bridge. Speaks MCP over stdio to a locally spawned
// host (Claude Desktop, Claude Code, any MCP client) and reads/writes the
// Harc database directly, so it works whether or not the app is running.
// It opens no network connections and holds no credentials: the agent
// brings its own model, on its own account. Register with e.g.
//
//   claude mcp add --scope user harc -- /Applications/Harc.app/Contents/MacOS/harc-mcp
//
// The process lifetime is owned by the host: it serves until stdin closes.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("harc-mcp: \(message)\n".utf8))
    exit(1)
}

// `--db <path>` override, for tests and seeded fixtures.
var dbURL = RecordingStore.defaultURL()
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--db":
        guard let path = argIterator.next() else { fail("--db needs a path") }
        dbURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "--help", "-h":
        print("""
        harc-mcp — MCP server over the Harc recordings library (stdio transport)

        Usage: harc-mcp [--db <path-to-Harc.db>]

        Tools: search_notes, get_recording, list_recent, update_summary,
               update_title, update_tags, set_speaker_name, append_note.
        Transcripts are read-only; notes are append-only. Writes regenerate
        the OKF .md projections.
        """)
        exit(0)
    default:
        fail("unknown argument '\(arg)' (try --help)")
    }
}

let store: RecordingStore
do {
    store = try await RecordingStore.onDisk(url: dbURL)
} catch let error as StoreError {
    if case .migrationFailed(let reason) = error {
        // The classic skew: an old bundled harc-mcp opening a database a
        // newer Harc already migrated further. Say so instead of dumping
        // GRDB internals.
        fail("Harc's database is newer than this server. Update Harc, then reconnect. (\(reason))")
    }
    fail(error.localizedDescription)
} catch {
    fail(error.localizedDescription)
}

let tools = HarcTools(store: store)

let server = Server(
    name: "harc",
    version: HarcVersion.current,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: HarcTools.definitions)
}

await server.withMethodHandler(CallTool.self) { params in
    await tools.call(name: params.name, arguments: params.arguments)
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
