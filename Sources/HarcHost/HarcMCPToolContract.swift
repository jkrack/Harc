import Foundation

/// JSON-compatible values accepted by the fixed local MCP allowlist. Keeping
/// this contract independent of the MCP SDK prevents the resident Host from
/// importing an agent transport or accidentally exposing SDK-specific types.
public enum HarcMCPToolValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([HarcMCPToolValue])
    case object([String: HarcMCPToolValue])

    public var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [HarcMCPToolValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([HarcMCPToolValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HarcMCPToolValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MCP tool value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct HarcMCPToolRequest: Codable, Equatable, Sendable {
    public let name: String
    public let arguments: [String: HarcMCPToolValue]?

    public init(name: String, arguments: [String: HarcMCPToolValue]?) {
        self.name = name
        self.arguments = arguments
    }
}

public struct HarcMCPToolResponse: Codable, Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public protocol HarcMCPToolCalling: Sendable {
    func call(_ request: HarcMCPToolRequest) async -> HarcMCPToolResponse
}
