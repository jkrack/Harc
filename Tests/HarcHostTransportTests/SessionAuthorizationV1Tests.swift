import Foundation
import GRPCCore
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import Testing

@Suite("Session authorization V1")
struct SessionAuthorizationV1Tests {
    @Test("missing authorization is rejected")
    func missingAuthorization() {
        expectInvalid([:])
    }

    @Test("duplicate authorization values are rejected")
    func duplicateAuthorization() {
        var metadata = validMetadata()
        metadata.addString(validHeader(), forKey: "authorization")
        expectInvalid(metadata)
    }

    @Test("binary authorization is rejected")
    func binaryAuthorization() {
        var metadata = Metadata()
        metadata.addBinary(
            Array(Data(repeating: 0x11, count: 48)),
            forKey: "authorization-bin"
        )
        expectInvalid(metadata)
    }

    @Test("padded base64url authorization is rejected")
    func paddedAuthorization() {
        expectInvalid(metadata("\(validHeader())="))
    }

    @Test("non-base64url authorization is rejected")
    func nonCanonicalAuthorization() {
        let standardBase64 = Data(repeating: 0xff, count: 48)
            .base64EncodedString()
        expectInvalid(metadata("HarcSession \(standardBase64)"))
    }

    @Test("wrong authorization scheme is rejected")
    func wrongScheme() {
        let encoded = String(validHeader().dropFirst("HarcSession ".count))
        expectInvalid(metadata("Bearer \(encoded)"))
    }

    @Test("wrong credential lengths are rejected")
    func wrongLength() {
        let short = base64URL(Data(repeating: 0x11, count: 47))
        let long = base64URL(Data(repeating: 0x11, count: 49))
        expectInvalid(metadata("HarcSession \(short)"))
        expectInvalid(metadata("HarcSession \(long)"))
    }

    @Test("valid authorization binds credential, served TLS SPKI, and upload-own scope")
    func validAuthorization() async throws {
        let credential = Data((0..<48).map { UInt8($0) })
        let tlsSPKISHA256 = Data(repeating: 0xa5, count: 32)
        let binding = try HarcGRPCServedIdentityBinding(
            generationID: UUID(),
            testTLSSPKISHA256: tlsSPKISHA256
        )
        let expected = authenticatedSession()
        let authenticator = SessionCredentialAuthenticatorFake(result: expected)

        let actual = try await HarcSessionAuthorizationV1
            .authenticateRecordingUpload(
                metadata: metadata(
                    "HarcSession \(base64URL(credential))"
                ),
                authenticator: authenticator,
                servedIdentityBinding: binding
            )

        #expect(actual == expected)
        let invocation = try #require(await authenticator.invocation())
        #expect(invocation.credential == credential)
        #expect(invocation.tlsSPKISHA256 == tlsSPKISHA256)
        #expect(invocation.requiredScope == .recordingUploadOwn)
    }

    private func expectInvalid(_ metadata: Metadata) {
        #expect(
            throws: HarcSessionAuthorizationV1Error.invalidAuthorization
        ) {
            try HarcSessionAuthorizationV1.credential(from: metadata)
        }
    }

    private func validMetadata() -> Metadata {
        metadata(validHeader())
    }

    private func validHeader() -> String {
        "HarcSession \(base64URL(Data(repeating: 0x11, count: 48)))"
    }

    private func metadata(_ authorization: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString(authorization, forKey: "authorization")
        return metadata
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func authenticatedSession() -> HostAuthenticatedSession {
        let hostKey = SoftwareP256SigningKey()
        let deviceKey = SoftwareP256SigningKey()
        return HostAuthenticatedSession(
            context: AuthenticatedDeviceContext(
                libraryID: .random(),
                hostAuthorityID: hostKey.publicKey.hostAuthorityID,
                authenticatedDeviceID: deviceKey.publicKey.deviceID,
                grantID: .random(),
                grantEpoch: .initial
            ),
            scopes: [.recordingUploadOwn],
            exactCapabilitiesBytes: Data([0x01]),
            capabilitiesSHA256: Data(repeating: 0x02, count: 32),
            protocolMinor: 0,
            selectedCodec: "alac",
            selectedContainer: "caf",
            expiresAt: Date(timeIntervalSince1970: 1_800_001_800)
        )
    }
}

private actor SessionCredentialAuthenticatorFake:
    HarcSessionCredentialAuthenticating
{
    struct Invocation: Equatable, Sendable {
        let credential: Data
        let tlsSPKISHA256: Data
        let requiredScope: AuthorizationScope?
    }

    private let result: HostAuthenticatedSession
    private var capturedInvocation: Invocation?

    init(result: HostAuthenticatedSession) {
        self.result = result
    }

    func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession {
        capturedInvocation = Invocation(
            credential: credential,
            tlsSPKISHA256: tlsSPKISHA256,
            requiredScope: requiredScope
        )
        return result
    }

    func invocation() -> Invocation? {
        capturedInvocation
    }
}
