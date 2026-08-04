import Foundation
import HarcIdentity
import HarcProtocol

public enum HarcCLICommand: Equatable, Sendable {
    case help
    case discover(timeoutSeconds: Double)
    case pair(
        ticketURI: String,
        clientKind: AdoptedClientKind,
        deviceLabel: String?,
        stateDirectory: String?
    )
    case status(stateDirectory: String?, uploadID: UUID?)
    case uploadFixture(seconds: Double, stateDirectory: String?)
}

public enum HarcCLIArgumentError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case duplicateOption(String)
    case unknownOption(String)
    case invalidValue(option: String, value: String)
    case requiredOption(String)

    public var description: String {
        switch self {
        case .missingCommand: "Missing command."
        case .unknownCommand(let command): "Unknown command: \(command)"
        case .missingValue(let option): "Missing value for \(option)."
        case .duplicateOption(let option): "Duplicate option: \(option)."
        case .unknownOption(let option): "Unknown option: \(option)."
        case .invalidValue(let option, let value):
            "Invalid value for \(option): \(value)"
        case .requiredOption(let option): "Required option missing: \(option)."
        }
    }
}

public enum HarcCLIArgumentParser {
    public static func parse(_ arguments: [String]) throws -> HarcCLICommand {
        guard let command = arguments.first else {
            throw HarcCLIArgumentError.missingCommand
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            guard tail.isEmpty else {
                throw HarcCLIArgumentError.unknownOption(tail[0])
            }
            return .help
        case "discover":
            let options = try parseOptions(tail, allowed: ["--timeout"])
            let timeout = try positiveDouble(
                options["--timeout"] ?? "5",
                option: "--timeout",
                maximum: 60
            )
            return .discover(timeoutSeconds: timeout)
        case "pair":
            let options = try parseOptions(
                tail,
                allowed: ["--ticket", "--kind", "--label", "--state-dir"]
            )
            guard let ticket = options["--ticket"] else {
                throw HarcCLIArgumentError.requiredOption("--ticket")
            }
            let kind: AdoptedClientKind
            switch options["--kind"] ?? "mac" {
            case "mac", "mac-client": kind = .macClient
            case "mobile", "ios": kind = .mobile
            case let value:
                throw HarcCLIArgumentError.invalidValue(
                    option: "--kind",
                    value: value
                )
            }
            return .pair(
                ticketURI: ticket,
                clientKind: kind,
                deviceLabel: options["--label"],
                stateDirectory: options["--state-dir"]
            )
        case "status":
            let options = try parseOptions(
                tail,
                allowed: ["--state-dir", "--upload"]
            )
            let uploadID: UUID?
            if let value = options["--upload"] {
                guard let parsed = UUID(uuidString: value) else {
                    throw HarcCLIArgumentError.invalidValue(
                        option: "--upload",
                        value: value
                    )
                }
                uploadID = parsed
            } else {
                uploadID = nil
            }
            return .status(
                stateDirectory: options["--state-dir"],
                uploadID: uploadID
            )
        case "upload-fixture":
            let options = try parseOptions(
                tail,
                allowed: ["--seconds", "--state-dir"]
            )
            let seconds = try positiveDouble(
                options["--seconds"] ?? "2",
                option: "--seconds",
                maximum: 30
            )
            return .uploadFixture(
                seconds: seconds,
                stateDirectory: options["--state-dir"]
            )
        default:
            throw HarcCLIArgumentError.unknownCommand(command)
        }
    }

    private static func parseOptions(
        _ arguments: [String],
        allowed: Set<String>
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw HarcCLIArgumentError.unknownOption(option)
            }
            guard result[option] == nil else {
                throw HarcCLIArgumentError.duplicateOption(option)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count,
                  !arguments[valueIndex].hasPrefix("--") else {
                throw HarcCLIArgumentError.missingValue(option)
            }
            result[option] = arguments[valueIndex]
            index += 2
        }
        return result
    }

    private static func positiveDouble(
        _ value: String,
        option: String,
        maximum: Double
    ) throws -> Double {
        guard let parsed = Double(value),
              parsed.isFinite,
              parsed > 0,
              parsed <= maximum else {
            throw HarcCLIArgumentError.invalidValue(
                option: option,
                value: value
            )
        }
        return parsed
    }
}

public struct HarcCLIRoute: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let serverHostname: String

    public init(host: String, port: UInt16, serverHostname: String) throws {
        guard !host.isEmpty, port > 0, !serverHostname.isEmpty else {
            throw HarcCLIArgumentError.invalidValue(
                option: "route",
                value: "empty host, port, or SNI"
            )
        }
        self.host = host
        self.port = port
        self.serverHostname = serverHostname
    }

    public init(ticket: PairingTicketV1) throws {
        guard let endpoint = ticket.endpoints.first(where: {
            $0.kind == .dnsHost
        }), let host = endpoint.textValue else {
            throw HarcCLIArgumentError.invalidValue(
                option: "--ticket",
                value: "ticket has no directly connectable DNS endpoint"
            )
        }
        try self.init(host: host, port: endpoint.port, serverHostname: host)
    }
}

public struct HarcCLIStateLocations: Equatable, Sendable {
    public let root: URL
    public let route: URL
    public let captures: URL

    public init(override: String?) {
        let root: URL
        if let override {
            root = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Harc/CLIClient", isDirectory: true)
        }
        self.root = root.standardizedFileURL
        route = self.root.appendingPathComponent("route.json")
        captures = self.root.appendingPathComponent("Captures", isDirectory: true)
    }
}

public enum HarcCLIRouteStore {
    public static func load(from url: URL) throws -> HarcCLIRoute {
        try JSONDecoder().decode(HarcCLIRoute.self, from: Data(contentsOf: url))
    }

    public static func save(_ route: HarcCLIRoute, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(route).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
