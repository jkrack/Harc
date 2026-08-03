import CryptoKit
import Foundation
import HarcProtocolWire
import Testing
@testable import HarcProtocol

@Suite("Harc protobuf schema contract")
struct SchemaContractTests {
    @Test("generated services pin all 25 V1 RPC names and streaming shapes")
    func serviceMethodInventory() {
        let descriptorGroups = [
            Harc_V1_HostInfoService.Method.descriptors,
            Harc_V1_SessionService.Method.descriptors,
            Harc_V1_PairingService.Method.descriptors,
            Harc_V1_RecordingTransferService.Method.descriptors,
            Harc_V1_LibraryService.Method.descriptors,
            Harc_V1_ProcessingService.Method.descriptors,
        ]

        let actual = descriptorGroups.flatMap { descriptors in
            descriptors.map { descriptor in
                let streamingShape = descriptor.type.map { String(describing: $0) } ?? "unknown"
                return "\(descriptor.fullyQualifiedMethod)|\(streamingShape)"
            }
        }

        let expected = [
            "harc.v1.HostInfoService/GetHostInfo|unary",
            "harc.v1.HostInfoService/NegotiateCapabilities|unary",
            "harc.v1.SessionService/BeginSession|unary",
            "harc.v1.SessionService/OpenSession|unary",
            "harc.v1.PairingService/BeginPairingClaim|unary",
            "harc.v1.PairingService/ProvePairingClaim|unary",
            "harc.v1.PairingService/GetPairingStatus|unary",
            "harc.v1.RecordingTransferService/BeginUpload|unary",
            "harc.v1.RecordingTransferService/DeclareChunks|unary",
            "harc.v1.RecordingTransferService/UploadChunks|bidirectionalStreaming",
            "harc.v1.RecordingTransferService/ReconcileUpload|unary",
            "harc.v1.RecordingTransferService/CommitUpload|unary",
            "harc.v1.RecordingTransferService/AbandonUpload|unary",
            "harc.v1.RecordingTransferService/GetRecordingStatus|unary",
            "harc.v1.RecordingTransferService/MintBackgroundCapability|unary",
            "harc.v1.LibraryService/BeginLibrarySnapshot|unary",
            "harc.v1.LibraryService/ListSnapshotPage|unary",
            "harc.v1.LibraryService/ListChanges|unary",
            "harc.v1.LibraryService/GetRecording|unary",
            "harc.v1.LibraryService/GetAudio|serverStreaming",
            "harc.v1.LibraryService/SearchMetadata|unary",
            "harc.v1.LibraryService/SearchTranscripts|unary",
            "harc.v1.LibraryService/ApplyMetadataMutation|unary",
            "harc.v1.ProcessingService/SubmitOwnArtifact|clientStreaming",
            "harc.v1.ProcessingService/GetProcessingStatus|unary",
        ]

        #expect(actual.count == 25)
        #expect(actual == expected)
    }

    @Test("generated RPCs pin all V1 request and response types")
    func rpcRequestResponseTypes() {
        let _: (Harc_V1_GetHostInfoRequestV1.Type, Harc_V1_GetHostInfoResponseV1.Type) =
            (Harc_V1_HostInfoService.Method.GetHostInfo.Input.self,
             Harc_V1_HostInfoService.Method.GetHostInfo.Output.self)
        let _: (Harc_V1_NegotiateCapabilitiesRequestV1.Type, Harc_V1_NegotiateCapabilitiesResponseV1.Type) =
            (Harc_V1_HostInfoService.Method.NegotiateCapabilities.Input.self,
             Harc_V1_HostInfoService.Method.NegotiateCapabilities.Output.self)

        let _: (Harc_V1_BeginSessionRequestV1.Type, Harc_V1_BeginSessionResponseV1.Type) =
            (Harc_V1_SessionService.Method.BeginSession.Input.self,
             Harc_V1_SessionService.Method.BeginSession.Output.self)
        let _: (Harc_V1_OpenSessionRequestV1.Type, Harc_V1_OpenSessionResponseV1.Type) =
            (Harc_V1_SessionService.Method.OpenSession.Input.self,
             Harc_V1_SessionService.Method.OpenSession.Output.self)

        let _: (Harc_V1_BeginPairingClaimRequestV1.Type, Harc_V1_BeginPairingClaimResponseV1.Type) =
            (Harc_V1_PairingService.Method.BeginPairingClaim.Input.self,
             Harc_V1_PairingService.Method.BeginPairingClaim.Output.self)
        let _: (Harc_V1_ProvePairingClaimRequestV1.Type, Harc_V1_ProvePairingClaimResponseV1.Type) =
            (Harc_V1_PairingService.Method.ProvePairingClaim.Input.self,
             Harc_V1_PairingService.Method.ProvePairingClaim.Output.self)
        let _: (Harc_V1_GetPairingStatusRequestV1.Type, Harc_V1_GetPairingStatusResponseV1.Type) =
            (Harc_V1_PairingService.Method.GetPairingStatus.Input.self,
             Harc_V1_PairingService.Method.GetPairingStatus.Output.self)

        let _: (Harc_V1_BeginUploadRequestV1.Type, Harc_V1_BeginUploadResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.BeginUpload.Input.self,
             Harc_V1_RecordingTransferService.Method.BeginUpload.Output.self)
        let _: (Harc_V1_DeclareChunksRequestV1.Type, Harc_V1_DeclareChunksResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.DeclareChunks.Input.self,
             Harc_V1_RecordingTransferService.Method.DeclareChunks.Output.self)
        let _: (Harc_V1_UploadChunkRequestV1.Type, Harc_V1_UploadChunkResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.UploadChunks.Input.self,
             Harc_V1_RecordingTransferService.Method.UploadChunks.Output.self)
        let _: (Harc_V1_ReconcileUploadRequestV1.Type, Harc_V1_ReconcileUploadResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.ReconcileUpload.Input.self,
             Harc_V1_RecordingTransferService.Method.ReconcileUpload.Output.self)
        let _: (Harc_V1_CommitUploadRequestV1.Type, Harc_V1_CommitUploadResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.CommitUpload.Input.self,
             Harc_V1_RecordingTransferService.Method.CommitUpload.Output.self)
        let _: (Harc_V1_AbandonUploadRequestV1.Type, Harc_V1_AbandonUploadResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.AbandonUpload.Input.self,
             Harc_V1_RecordingTransferService.Method.AbandonUpload.Output.self)
        let _: (Harc_V1_GetRecordingStatusRequestV1.Type, Harc_V1_GetRecordingStatusResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.GetRecordingStatus.Input.self,
             Harc_V1_RecordingTransferService.Method.GetRecordingStatus.Output.self)
        let _: (Harc_V1_MintBackgroundCapabilityRequestV1.Type, Harc_V1_MintBackgroundCapabilityResponseV1.Type) =
            (Harc_V1_RecordingTransferService.Method.MintBackgroundCapability.Input.self,
             Harc_V1_RecordingTransferService.Method.MintBackgroundCapability.Output.self)

        let _: (Harc_V1_BeginLibrarySnapshotRequestV1.Type, Harc_V1_BeginLibrarySnapshotResponseV1.Type) =
            (Harc_V1_LibraryService.Method.BeginLibrarySnapshot.Input.self,
             Harc_V1_LibraryService.Method.BeginLibrarySnapshot.Output.self)
        let _: (Harc_V1_ListSnapshotPageRequestV1.Type, Harc_V1_ListSnapshotPageResponseV1.Type) =
            (Harc_V1_LibraryService.Method.ListSnapshotPage.Input.self,
             Harc_V1_LibraryService.Method.ListSnapshotPage.Output.self)
        let _: (Harc_V1_ListChangesRequestV1.Type, Harc_V1_ListChangesResponseV1.Type) =
            (Harc_V1_LibraryService.Method.ListChanges.Input.self,
             Harc_V1_LibraryService.Method.ListChanges.Output.self)
        let _: (Harc_V1_GetRecordingRequestV1.Type, Harc_V1_GetRecordingResponseV1.Type) =
            (Harc_V1_LibraryService.Method.GetRecording.Input.self,
             Harc_V1_LibraryService.Method.GetRecording.Output.self)
        let _: (Harc_V1_GetAudioRequestV1.Type, Harc_V1_GetAudioResponseV1.Type) =
            (Harc_V1_LibraryService.Method.GetAudio.Input.self,
             Harc_V1_LibraryService.Method.GetAudio.Output.self)
        let _: (Harc_V1_SearchMetadataRequestV1.Type, Harc_V1_SearchMetadataResponseV1.Type) =
            (Harc_V1_LibraryService.Method.SearchMetadata.Input.self,
             Harc_V1_LibraryService.Method.SearchMetadata.Output.self)
        let _: (Harc_V1_SearchTranscriptsRequestV1.Type, Harc_V1_SearchTranscriptsResponseV1.Type) =
            (Harc_V1_LibraryService.Method.SearchTranscripts.Input.self,
             Harc_V1_LibraryService.Method.SearchTranscripts.Output.self)
        let _: (Harc_V1_ApplyMetadataMutationRequestV1.Type, Harc_V1_ApplyMetadataMutationResponseV1.Type) =
            (Harc_V1_LibraryService.Method.ApplyMetadataMutation.Input.self,
             Harc_V1_LibraryService.Method.ApplyMetadataMutation.Output.self)

        let _: (Harc_V1_SubmitOwnArtifactRequestV1.Type, Harc_V1_SubmitOwnArtifactResponseV1.Type) =
            (Harc_V1_ProcessingService.Method.SubmitOwnArtifact.Input.self,
             Harc_V1_ProcessingService.Method.SubmitOwnArtifact.Output.self)
        let _: (Harc_V1_GetProcessingStatusRequestV1.Type, Harc_V1_GetProcessingStatusResponseV1.Type) =
            (Harc_V1_ProcessingService.Method.GetProcessingStatus.Input.self,
             Harc_V1_ProcessingService.Method.GetProcessingStatus.Output.self)
    }

    @Test("all 28 closed V1 enums default to their zero unspecified value")
    func enumZeroValues() {
        let zeroValues: [(name: String, rawValue: Int)] = [
            ("CanonicalPCMEncodingV1", Harc_V1_CanonicalPCMEncodingV1().rawValue),
            ("LosslessAudioCodecV1", Harc_V1_LosslessAudioCodecV1().rawValue),
            ("LosslessAudioContainerV1", Harc_V1_LosslessAudioContainerV1().rawValue),
            ("RecordingProcessingStateV1", Harc_V1_RecordingProcessingStateV1().rawValue),
            ("RecordingProjectionStateV1", Harc_V1_RecordingProjectionStateV1().rawValue),
            ("HarcErrorCodeV1", Harc_V1_HarcErrorCodeV1().rawValue),
            ("AuthorizationScopeV1", Harc_V1_AuthorizationScopeV1().rawValue),
            ("PairingClaimStateV1", Harc_V1_PairingClaimStateV1().rawValue),
            ("UploadProfilePurposeV1", Harc_V1_UploadProfilePurposeV1().rawValue),
            ("CaptureFinalizationReasonV1", Harc_V1_CaptureFinalizationReasonV1().rawValue),
            ("CaptureDiscontinuityReasonV1", Harc_V1_CaptureDiscontinuityReasonV1().rawValue),
            ("CaptureCanonicalizationPolicyV1", Harc_V1_CaptureCanonicalizationPolicyV1().rawValue),
            ("BeginUploadDispositionV1", Harc_V1_BeginUploadDispositionV1().rawValue),
            ("ChunkDeclarationDispositionV1", Harc_V1_ChunkDeclarationDispositionV1().rawValue),
            ("ChunkDeclarationConflictKindV1", Harc_V1_ChunkDeclarationConflictKindV1().rawValue),
            ("RejectedChunkReasonV1", Harc_V1_RejectedChunkReasonV1().rawValue),
            ("UploadTerminalReasonV1", Harc_V1_UploadTerminalReasonV1().rawValue),
            ("CommitUploadDispositionV1", Harc_V1_CommitUploadDispositionV1().rawValue),
            ("RecordingIngestStateV1", Harc_V1_RecordingIngestStateV1().rawValue),
            ("CanonicalAudioAvailabilityV1", Harc_V1_CanonicalAudioAvailabilityV1().rawValue),
            ("LibraryChangeOperationV1", Harc_V1_LibraryChangeOperationV1().rawValue),
            ("ListChangesDispositionV1", Harc_V1_ListChangesDispositionV1().rawValue),
            ("RecordingDetailFieldV1", Harc_V1_RecordingDetailFieldV1().rawValue),
            ("AudioRepresentationV1", Harc_V1_AudioRepresentationV1().rawValue),
            ("MetadataSearchSortV1", Harc_V1_MetadataSearchSortV1().rawValue),
            ("TranscriptSearchModeV1", Harc_V1_TranscriptSearchModeV1().rawValue),
            ("ProcessingBundleEntryTypeV1", Harc_V1_ProcessingBundleEntryTypeV1().rawValue),
            ("ProcessingSubmissionDispositionV1", Harc_V1_ProcessingSubmissionDispositionV1().rawValue),
        ]

        #expect(zeroValues.count == 28)
        for value in zeroValues {
            #expect(value.rawValue == 0, "\(value.name) must preserve UNSPECIFIED = 0")
        }
    }

    @Test("all schema sources use the frozen package and Swift prefix without storage fields")
    func schemaSourceRules() throws {
        let allProtocolSources = try FileManager.default.contentsOfDirectory(
            at: Self.repositoryRoot.appending(path: "Protos"),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "proto" }
        .map(\.lastPathComponent)
        .sorted()
        #expect(allProtocolSources == Self.schemaNames)

        let handwrittenWireSources = try FileManager.default.contentsOfDirectory(
            at: Self.repositoryRoot.appending(path: "Protos"),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.lastPathComponent)
        .sorted()
        #expect(handwrittenWireSources == ["Module.swift"])
        let moduleSentinel = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Protos/Module.swift"),
            encoding: .utf8
        )
        let declarations = moduleSentinel.split(whereSeparator: \.isNewline).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        #expect(declarations.isEmpty)

        let sources = try Self.loadSchemaSources()
        #expect(sources.map(\.name) == Self.schemaNames)

        var pathShapedFields: [String] = []
        var databaseFields: [String] = []
        for source in sources {
            #expect(Self.occurrenceCount(of: "syntax = \"proto3\";", in: source.text) == 1)
            #expect(Self.occurrenceCount(of: "package harc.v1;", in: source.text) == 1)
            #expect(Self.occurrenceCount(of: "option swift_prefix = \"Harc_V1_\";", in: source.text) == 1)

            let code = Self.removingLineComments(from: source.text)
            #expect(!Self.contains(pattern: #"\bmap\s*<"#, in: code))

            for field in Self.fieldNames(in: code) {
                if field == "path" || field.hasSuffix("_path") {
                    pathShapedFields.append("\(source.name):\(field)")
                }
                if Self.contains(
                    pattern: #"(^|_)(db|database|grdb|row)(_id)?($|_)"#,
                    in: field
                ) {
                    databaseFields.append("\(source.name):\(field)")
                }
            }
        }

        // This is the capability-bound HTTP request target, not a host path.
        #expect(pathShapedFields == ["harc_transfer.proto:http_path"])
        #expect(databaseFields.isEmpty)
    }

    @Test("schema and generator sources match the reviewed V1 SHA-256 inventory")
    func schemaChecksums() throws {
        let inventoryURL = Self.repositoryRoot
            .appending(path: "Protos/Fixtures/harc-protocol-sources-v1.sha256")
        let inventory = try String(contentsOf: inventoryURL, encoding: .utf8)
        let entries = try inventory.split(whereSeparator: \.isNewline).map { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 2 else {
                throw SchemaFixtureError.malformedChecksumLine(String(line))
            }
            return (hash: String(columns[0]), path: String(columns[1]))
        }

        let expectedPaths = ["Protos/grpc-swift-proto-generator-config.json"]
            + Self.schemaNames.map { "Protos/\($0)" }
        #expect(entries.map(\.path) == expectedPaths)

        for entry in entries {
            let bytes = try Data(contentsOf: Self.repositoryRoot.appending(path: entry.path))
            let actualHash = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(actualHash == entry.hash, "Review and deliberately refresh \(entry.path)'s V1 checksum")
        }
    }

    @Test("processing upload and audio download pin bounded contiguous stream framing")
    func streamingFramingRules() throws {
        let processing = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Protos/harc_processing.proto"),
            encoding: .utf8
        )
        let processingClauses = [
            "The first request MUST carry begin, begin MUST occur exactly once",
            "Frames MUST start at frame_index 0 and byte_offset 0.",
            "frame.data MUST contain 1...1,048,576 bytes.",
            "MUST NOT allocate from a peer-supplied length,",
            "The client's successful half-close is the only end-of-bundle marker.",
            "count and SHA-256 to equal the signed exact_bundle_byte_length and",
            "exact_bundle_sha256. Early EOF, extra/trailing bytes, or mismatch fails.",
        ]
        for clause in processingClauses {
            #expect(processing.contains(clause), "Missing processing stream rule: \(clause)")
        }

        let library = try String(
            contentsOf: Self.repositoryRoot.appending(path: "Protos/harc_library.proto"),
            encoding: .utf8
        )
        let libraryClauses = [
            "Absent is identical to zero. It MUST NOT exceed the",
            "successful server half-close. A resumed consumer MUST retain and hash the",
            "The first response MUST carry descriptor, descriptor MUST occur exactly",
            "The first frame byte_offset MUST equal resume_byte_offset.",
            "frame.data MUST contain 1...4,194,304 bytes.",
            "MUST NOT allocate from a",
            "The server's successful half-close is the only EOF marker",
            "verify the complete representation's exact byte count and content_sha256,",
            "fails and MUST NOT expose partial audio as complete.",
        ]
        for clause in libraryClauses {
            #expect(library.contains(clause), "Missing audio stream rule: \(clause)")
        }
    }

    @Test("decoded control protobufs enforce the one MiB ceiling before interpretation")
    func decodedControlPayloadCeiling() throws {
        let limit = HarcProtocolLimits.decodedControlPayloadBytes
        #expect(limit == 1_048_576)

        // A bytes field at this size has a one-byte tag and three-byte length.
        var atLimitMessage = Harc_V1_ExactSignedObjectV1()
        atLimitMessage.framedBytes = Data(repeating: 0x5a, count: limit - 4)
        let atLimitBytes = try atLimitMessage.serializedData()
        #expect(atLimitBytes.count == limit)

        let accepted = try HarcExactProtobufPayload(
            decoding: atLimitBytes,
            as: Harc_V1_ExactSignedObjectV1.self
        )
        #expect(accepted.exactBytes == atLimitBytes)
        #expect(accepted.message.framedBytes == atLimitMessage.framedBytes)

        var overLimitMessage = Harc_V1_ExactSignedObjectV1()
        overLimitMessage.framedBytes = Data(repeating: 0x5a, count: limit - 3)
        let overLimitBytes = try overLimitMessage.serializedData()
        #expect(overLimitBytes.count == limit + 1)

        #expect(throws: HarcProtobufConversionError.inputTooLarge(
            limit: limit,
            actual: limit + 1
        )) {
            try HarcExactProtobufPayload(
                decoding: overLimitBytes,
                as: Harc_V1_ExactSignedObjectV1.self
            )
        }
        #expect(throws: HarcProtobufConversionError.inputTooLarge(
            limit: limit,
            actual: limit + 1
        )) {
            try HarcExactProtobufPayload(serializingOnce: overLimitMessage)
        }
    }

    private static let schemaNames = [
        "harc_common.proto",
        "harc_identity.proto",
        "harc_library.proto",
        "harc_migration.proto",
        "harc_pairing.proto",
        "harc_processing.proto",
        "harc_transfer.proto",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadSchemaSources() throws -> [(name: String, text: String)] {
        try schemaNames.map { name in
            let url = repositoryRoot.appending(path: "Protos/\(name)")
            return (name, try String(contentsOf: url, encoding: .utf8))
        }
    }

    private static func occurrenceCount(of needle: String, in value: String) -> Int {
        value.components(separatedBy: needle).count - 1
    }

    private static func removingLineComments(from value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    private static func fieldNames(in source: String) -> [String] {
        captures(
            pattern: #"\b([a-z][a-z0-9_]*)\s*=\s*[0-9]+\s*(?:\[[^\]]*\])?\s*;"#,
            in: source
        )
    }

    private static func contains(pattern: String, in value: String) -> Bool {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func captures(pattern: String, in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[captureRange])
        }
    }
}

private enum SchemaFixtureError: Error {
    case malformedChecksumLine(String)
}
