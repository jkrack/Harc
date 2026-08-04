import Foundation

@main
struct HarcCLIEntry {
    static func main() async {
        do {
            let command = try HarcCLIArgumentParser.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            if #available(macOS 15.0, *) {
                try await HarcCLIApplication().run(command)
            } else {
                throw HarcCLIEntryError.unsupportedOperatingSystem
            }
        } catch {
            FileHandle.standardError.write(
                Data("harcctl: \(error)\n".utf8)
            )
            FileHandle.standardError.write(
                Data("Run 'harcctl help' for usage.\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private enum HarcCLIEntryError: Error, CustomStringConvertible {
    case unsupportedOperatingSystem

    var description: String {
        "harcctl requires macOS 15 or newer."
    }
}
