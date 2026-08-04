#if os(macOS)
import Darwin
import Foundation
import HarcHost

enum HarcLocalMCPIPCProtocol {
    static let magic = "HARC-MCP-IPC-V1"
    static let version: UInt16 = 1
    static let nonceLength = 32
    static let maximumFrameLength = 16 * 1_024 * 1_024
}

struct HarcLocalMCPClientHello: Codable, Equatable, Sendable {
    let magic: String
    let version: UInt16
    let nonce: Data
}

struct HarcLocalMCPServerHello: Codable, Equatable, Sendable {
    let magic: String
    let selectedVersion: UInt16
    let clientNonce: Data
    let serverNonce: Data
}

struct HarcLocalMCPRequestEnvelope: Codable, Equatable, Sendable {
    let requestID: UUID
    let request: HarcMCPToolRequest
}

struct HarcLocalMCPResponseEnvelope: Codable, Equatable, Sendable {
    let requestID: UUID
    let response: HarcMCPToolResponse
}

enum HarcLocalMCPIPCError: Error, LocalizedError, Equatable {
    case systemCall(operation: String, code: Int32)
    case peerAuthorizationFailed
    case invalidFrameLength
    case connectionClosed
    case invalidHello
    case unsupportedProtocolVersion
    case nonceMismatch
    case responseMismatch
    case invalidToolName
    case unsignedOrUnexpectedOwnCode

    var errorDescription: String? {
        switch self {
        case .systemCall(let operation, let code):
            return "Local MCP IPC \(operation) failed (errno \(code))."
        case .peerAuthorizationFailed:
            return "The local MCP peer did not have the required signed identity."
        case .invalidFrameLength:
            return "The local MCP IPC frame length is invalid."
        case .connectionClosed:
            return "The local MCP IPC connection closed before the response completed."
        case .invalidHello:
            return "The local MCP IPC hello is invalid."
        case .unsupportedProtocolVersion:
            return "The local MCP IPC protocol version is unsupported."
        case .nonceMismatch:
            return "The local MCP IPC nonce response did not match."
        case .responseMismatch:
            return "The local MCP IPC response did not match its request."
        case .invalidToolName:
            return "The local MCP tool is not in the fixed allowlist."
        case .unsignedOrUnexpectedOwnCode:
            return "Host-mode MCP requires the signed Harc release app and helper."
        }
    }
}

enum HarcLocalMCPFrameCodec {
    static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count > 0,
              payload.count <= HarcLocalMCPIPCProtocol.maximumFrameLength else {
            throw HarcLocalMCPIPCError.invalidFrameLength
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) { bytes in
            try writeAll(bytes, to: descriptor)
        }
        try payload.withUnsafeBytes { bytes in
            try writeAll(bytes, to: descriptor)
        }
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        from descriptor: Int32
    ) throws -> T {
        var length = UInt32.zero
        try withUnsafeMutableBytes(of: &length) { bytes in
            try readAll(bytes, from: descriptor)
        }
        let count = Int(UInt32(bigEndian: length))
        guard count > 0,
              count <= HarcLocalMCPIPCProtocol.maximumFrameLength else {
            throw HarcLocalMCPIPCError.invalidFrameLength
        }
        var payload = Data(count: count)
        try payload.withUnsafeMutableBytes { bytes in
            try readAll(bytes, from: descriptor)
        }
        return try JSONDecoder().decode(type, from: payload)
    }

    private static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset
            )
            if result > 0 { offset += result; continue }
            if result == -1, errno == EINTR { continue }
            throw HarcLocalMCPIPCError.systemCall(
                operation: "write",
                code: errno
            )
        }
    }

    private static func readAll(
        _ bytes: UnsafeMutableRawBufferPointer,
        from descriptor: Int32
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.read(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset
            )
            if result > 0 { offset += result; continue }
            if result == 0 { throw HarcLocalMCPIPCError.connectionClosed }
            if result == -1, errno == EINTR { continue }
            throw HarcLocalMCPIPCError.systemCall(
                operation: "read",
                code: errno
            )
        }
    }

    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< HarcLocalMCPIPCProtocol.nonceLength).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}
#endif
