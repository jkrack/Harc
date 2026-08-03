import CryptoKit
import Foundation
import HarcDomain
@testable import HarcIdentity
@testable import HarcProtocol
import HarcProtocolWire
import Testing

@Suite("Frozen Harc V1 interoperability vectors")
struct GoldenWireVectorTests {
    @Test("all nine registry rows preserve and verify their checked-in exact frame")
    func signedRegistryRows() throws {
        let fixture = try GoldenWireCorpus.load()
        let rows = fixture.values.values
            .filter { $0.key.hasPrefix("signed.") }
            .sorted { $0.key < $1.key }

        #expect(rows.count == 9)
        for row in rows {
            #expect(row.columns.count == 4)
            let frame = try GoldenWireCorpus.base64(row.columns[1], field: row.key)
            let expectedObjectID = try Data(protocolHex: row.columns[2])
            let signerSeed = try #require(UInt8(row.columns[3]))
            let signer = ProtocolCodecFixtures.key(signerSeed)
            let object = try HarcSignedObjectV1.decode(frame)

            #expect("signed.\(object.header.messageType.rawValue)" == row.key)
            #expect(object.exactFramedBytes == frame)
            #expect(object.objectID.rawBytes == expectedObjectID)

            let bindings = HarcSignedPayloadBindingsV1(
                protocolVersion: object.header.protocolVersion,
                libraryID: object.header.libraryID,
                hostAuthorityID: object.header.hostAuthorityID,
                issuedAtUnixMilliseconds: object.header.issuedAtUnixMilliseconds,
                signerDeviceID: object.header.signerDeviceID,
                grantID: object.header.grantID,
                grantEpoch: object.header.grantEpoch == 0 ? nil : object.header.grantEpoch,
                operationID: object.header.operationID,
                expiresAtUnixMilliseconds: object.header.expiresAtUnixMilliseconds,
                expectedRevision: object.header.expectedRevision
            )
            try object.verifyRegistered(using: signer.publicKey, payloadBindings: bindings)
        }
    }

    @Test("transport, ticket, URI, pairing proof, and SAS remain byte-for-byte frozen")
    func trustBootstrapVectors() throws {
        let fixture = try GoldenWireCorpus.load()

        let transportPayload = try fixture.base64Value("transport.payload")
        let transportFrame = try fixture.base64Value("transport.frame")
        let verified = try VerifiedHostTransportSetV1.decode(
            transportFrame,
            hostAuthorityPublicKey: ProtocolCodecFixtures.key(10).publicKey
        )
        #expect(verified.transportSet.encoded() == transportPayload)
        #expect(verified.exactSignedBytes == transportFrame)

        let ticketBytes = try fixture.base64Value("ticket.binary")
        let ticketURI = try fixture.textValue("ticket.uri")
        let ticket = try PairingTicketV1.decode(
            ticketBytes,
            atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
        )
        #expect(try ticket.encoded() == ticketBytes)
        #expect(try ticket.encodedURI() == ticketURI)
        #expect(try PairingTicketV1.decodeURI(
            ticketURI,
            atUnixMilliseconds: ProtocolCodecFixtures.issuedAt + 1
        ) == ticket)

        let transcriptBytes = try fixture.base64Value("pairing.transcript")
        let transcript = try PairingTranscriptV1.decode(transcriptBytes)
        let proofDigest = try Data(protocolHex: fixture.textValue("pairing.proof-digest"))
        let signature = try P256RawSignature(fixture.base64Value("pairing.signature"))
        #expect(try transcript.encoded() == transcriptBytes)
        #expect(try transcript.clientProofDigest().rawBytes == proofDigest)
        try transcript.verifyClientProof(signature)

        let phrase = try HarcSASDictionaryV1.bundled().phrase(
            for: transcript,
            clientSignature: signature
        )
        let expectedSASDigest = try Data(protocolHex: fixture.textValue("pairing.sas-digest"))
        let expectedSASIndexes = try fixture.textValue("pairing.sas-indexes")
        let expectedSASWords = try fixture.textValue("pairing.sas-words")
        #expect(phrase.digest == expectedSASDigest)
        #expect(phrase.indexes.map(String.init).joined(separator: ",") == expectedSASIndexes)
        #expect(phrase.displayedPhrase == expectedSASWords)
    }

    @Test("session proof and exact containers remain byte-for-byte frozen")
    func sessionAndContainerVectors() throws {
        let fixture = try GoldenWireCorpus.load()
        let sessionBytes = try fixture.base64Value("session.transcript")
        let session = try SessionTranscriptV1.decode(sessionBytes)
        let sessionSignature = try P256RawSignature(fixture.base64Value("session.signature"))
        let expectedSessionDigest = try Data(
            protocolHex: fixture.textValue("session.proof-digest")
        )
        #expect(session.encoded() == sessionBytes)
        #expect(session.clientProofDigest().rawBytes == expectedSessionDigest)
        try session.verifyClientProof(
            sessionSignature,
            using: ProtocolCodecFixtures.key(31).publicKey
        )

        let audioBatchBytes = try fixture.base64Value("audio-batch.exact")
        let audioBatch = try HarcAudioBatchV1.decode(audioBatchBytes)
        #expect(audioBatch.exactBytes == audioBatchBytes)
        #expect(audioBatch.encodedChunks == [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])])

        let processingBytes = try fixture.base64Value("processing-bundle.exact")
        let processing = try HarcProcessingBundleV1.decode(
            processingBytes,
            totalCanonicalFrames: 4
        )
        #expect(processing.exactBytes == processingBytes)
        #expect(processing.entries.count == 4)
    }

    @Test("current-minor and additive-unknown protobuf bytes are preserved exactly")
    func compatibilityVectors() throws {
        let fixture = try GoldenWireCorpus.load()
        let capabilityBytes = try fixture.base64Value("capability.negotiated.v1-exact")
        let additiveCapabilityBytes = try fixture.base64Value(
            "capability.negotiated.v1-additive-unknown"
        )
        let expectedCapabilityDigest = try Data(
            protocolHex: fixture.textValue("capability.negotiated.v1-sha256")
        )
        let capabilityPolicy = try HarcCapabilityPolicyV1(
            compatibility: HarcProtobufCompatibilityPolicy(
                versionPolicy: .currentV1,
                supportedRequiredFeatures: ["transfer.chunk.v1"]
            ),
            supportedFeatureIDs: ["capture.gaps.v1", "transfer.chunk.v1"],
            supportedDescriptorSchemaIDs: ["harc.chunk-descriptor.v1"],
            supportedEncodings: [.rawPCMFixture],
            allowRawPCMFixture: true
        )
        let capability = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: capabilityBytes,
            expectedSHA256: expectedCapabilityDigest,
            policy: capabilityPolicy
        )
        let additiveCapability = try HarcValidatedNegotiatedCapabilitiesV1(
            decoding: additiveCapabilityBytes,
            expectedSHA256: Data(SHA256.hash(data: additiveCapabilityBytes)),
            policy: capabilityPolicy
        )
        #expect(capability.exactPayload.exactBytes == capabilityBytes)
        #expect(capability.exactSHA256 == expectedCapabilityDigest)
        #expect(capability.selectedFeatureIDs == ["capture.gaps.v1", "transfer.chunk.v1"])
        #expect(capability.descriptorSchemaID == "harc.chunk-descriptor.v1")
        #expect(capability.encoding == .rawPCMFixture)
        #expect(capability.canonicalFormat == .harcV1)
        #expect(additiveCapability.exactPayload.exactBytes == additiveCapabilityBytes)
        #expect(additiveCapability.selectedFeatureIDs == capability.selectedFeatureIDs)
        #expect(additiveCapabilityBytes != capabilityBytes)

        let current = try fixture.base64Value("compatibility.v1-current")
        let additive = try fixture.base64Value("compatibility.v1-additive-unknown")

        let currentPayload = try HarcExactProtobufPayload(
            decoding: current,
            as: Harc_V1_ProtocolVersionV1.self
        )
        let additivePayload = try HarcExactProtobufPayload(
            decoding: additive,
            as: Harc_V1_ProtocolVersionV1.self
        )
        #expect(currentPayload.message.major == 1)
        #expect(additivePayload.message.major == 1)
        #expect(currentPayload.exactBytes == current)
        #expect(additivePayload.exactBytes == additive)
        #expect(additive != current)
    }
}

private struct GoldenWireCorpus {
    struct Value {
        let key: String
        let columns: [String]
    }

    let values: [String: Value]

    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Protos/Fixtures/harc-wire-v1-golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: Value] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.hasPrefix("#") else { continue }
            let columns = line.components(separatedBy: "|")
            guard columns.count >= 2, values[columns[0]] == nil else {
                throw GoldenWireFixtureError.malformedLine(line)
            }
            values[columns[0]] = Value(key: columns[0], columns: columns)
        }
        return Self(values: values)
    }

    func textValue(_ key: String) throws -> String {
        guard let value = values[key], value.columns.count == 2 else {
            throw GoldenWireFixtureError.missingKey(key)
        }
        return value.columns[1]
    }

    func base64Value(_ key: String) throws -> Data {
        try Self.base64(textValue(key), field: key)
    }

    static func base64(_ value: String, field: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw GoldenWireFixtureError.invalidBase64(field)
        }
        return data
    }
}

private enum GoldenWireFixtureError: Error {
    case malformedLine(String)
    case missingKey(String)
    case invalidBase64(String)
}
