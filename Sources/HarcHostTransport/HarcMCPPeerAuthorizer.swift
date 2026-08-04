#if os(macOS)
import Darwin
import Foundation
import HarcIPCSystem
import Security

public protocol MCPPeerAuthorizing: Sendable {
    func authorize(
        peerOnConnectedSocket descriptor: Int32,
        expectedIdentifier: String
    ) throws
}

/// Production peer authorization derives the Team Identifier from this live,
/// validated process and applies the exact audit-token-selected requirement to
/// the connected peer. It has no runtime bypass or environment override.
public struct HarcMCPCodeSigningPeerAuthorizer: MCPPeerAuthorizing, Sendable {
    private let teamIdentifier: String

    public init(expectedOwnIdentifier: String) throws {
        var ownCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &ownCode) == errSecSuccess,
              let ownCode else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        guard SecCodeCheckValidity(
            ownCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        var ownStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            ownCode,
            SecCSFlags(),
            &ownStaticCode
        ) == errSecSuccess,
              let ownStaticCode else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            ownStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              values[kSecCodeInfoIdentifier] as? String == expectedOwnIdentifier,
              let team = values[kSecCodeInfoTeamIdentifier] as? String,
              Self.isSafeRequirementAtom(team) else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        let ownRequirement = try Self.requirement(
            identifier: expectedOwnIdentifier,
            teamIdentifier: team
        )
        guard SecCodeCheckValidity(
            ownCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            ownRequirement
        ) == errSecSuccess else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        teamIdentifier = team
    }

    public func authorize(
        peerOnConnectedSocket descriptor: Int32,
        expectedIdentifier: String
    ) throws {
        var peerEUID = uid_t.zero
        var peerEGID = gid_t.zero
        var token = HarcIPCAuditToken()
        guard harc_ipc_copy_peer_identity(
            descriptor,
            &peerEUID,
            &peerEGID,
            &token
        ) == 0,
              peerEUID == geteuid() else {
            throw HarcLocalMCPIPCError.peerAuthorizationFailed
        }
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var peerCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &peerCode
        ) == errSecSuccess,
              let peerCode else {
            throw HarcLocalMCPIPCError.peerAuthorizationFailed
        }
        let peerRequirement = try Self.requirement(
            identifier: expectedIdentifier,
            teamIdentifier: teamIdentifier
        )
        guard SecCodeCheckValidity(
            peerCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            peerRequirement
        ) == errSecSuccess else {
            throw HarcLocalMCPIPCError.peerAuthorizationFailed
        }
    }

    private static func requirement(
        identifier: String,
        teamIdentifier: String
    ) throws -> SecRequirement {
        guard isSafeRequirementAtom(identifier),
              isSafeRequirementAtom(teamIdentifier) else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        let source = """
            identifier "\(identifier)" and anchor apple generic and \
            certificate leaf[subject.OU] = "\(teamIdentifier)"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement else {
            throw HarcLocalMCPIPCError.unsignedOrUnexpectedOwnCode
        }
        return requirement
    }

    private static func isSafeRequirementAtom(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "." || $0 == "-"
        }
    }
}
#endif
