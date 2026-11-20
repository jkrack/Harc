import Foundation
import GRDB
import HarcClient
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol
import HarcProtocolWire
import HarcStore
import HarcTransfer
import Testing
@testable import Harc

@Suite("Bounded redacted Host processing diagnostics")
struct HarcHostProcessingDiagnosticTests {
    typealias Diagnostic = HarcHostProcessingDiagnostic

    @Test func entireCatalogIsBoundedAndWireCompatible() throws {
        var codes = Set<String>()
        for phase in Diagnostic.Phase.allCases {
            for cause in Diagnostic.Cause.allCases {
                let diagnostic = Diagnostic(phase: phase, cause: cause)
                let failure = diagnostic.failure
                #expect(codes.insert(failure.code).inserted)
                #expect(failure.code.utf8.count <= 128)
                #expect(try #require(failure.message).utf8.count < 512)
                #expect(diagnostic.logLine.utf8.count < 768)
                #expect(diagnostic.logLine.filter { $0 == "\n" }.count == 1)
                #expect(try JSONDecoder().decode(ProcessingFailure.self,
                    from: JSONEncoder().encode(failure)) == failure)
                #expect(try Harc_V1_ProcessingFailureV1(failure).domainValue() == failure)
            }
        }
    }

    @Test func typedCausesDiscardEveryAssociatedValue() throws {
        let secret = "SYNTHETIC-SECRET /private/example.wav transcript\nforged-log-record"
        let cases: [(any Error, Diagnostic.Cause)] = [
            (HarcHostError.canonicalHashMismatch, .hostCanonicalHashMismatch),
            (HarcHostError.canonicalArtifactIdentityMismatch, .hostCanonicalArtifactIdentityMismatch),
            (HarcHostError.publicationIO(secret), .hostPublicationIO),
            (HarcHostError.publicationRecoveryRequired(secret), .hostPublicationRecoveryRequired),
            (HarcHostError.databaseFailure(secret), .hostDatabaseFailure),
            (StoreError.canonicalArtifactIdentityMismatch, .storeCanonicalArtifactIdentityMismatch),
            (StoreError.readFailed(secret), .storeReadFailed),
            (StoreError.invalidData(secret), .storeInvalidData),
            (ClientError.daemonLaunchFailed(secret), .clientDaemonLaunchFailed),
            (ClientError.daemonNotReachable(secret), .clientDaemonNotReachable),
            (ClientError.transcribeFailed(code: secret, message: secret), .clientTranscribeFailed),
            (ClientError.ipcDecodeFailed(secret), .clientIpcDecodeFailed),
            (ClientError.timeout(seconds: Int.max), .clientTimeout),
            (HarcProtocolCodecError.headerPayloadMismatch(field: secret), .protocolHeaderPayloadMismatch),
            (HarcProtocolCodecError.invalidSignature, .protocolInvalidSignature),
            (HarcProtobufConversionError.missingField(secret), .protobufMissingField),
            (TransferValidationError.evidenceBindingMismatch(field: secret), .transferEvidenceBindingMismatch),
            (DomainValidationError.invalidState(reason: secret), .domainInvalidState),
            (IdentityCryptoError.invalidPublicKeyPrefix(actual: 123), .identityInvalidPublicKeyPrefix),
            (CancellationError(), .cancelled),
            (EncodingError.invalidValue(secret, .init(codingPath: [], debugDescription: secret)), .encodingInvalidValue),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret)), .decodingCorrupt),
            (DatabaseError(resultCode: .SQLITE_BUSY, message: secret, sql: secret), .sqliteBusy),
            (DatabaseError(resultCode: .SQLITE_FULL, message: secret, sql: secret), .sqliteFull),
            (DatabaseError(resultCode: .SQLITE_IOERR_FSYNC, message: secret, sql: secret), .sqliteSync),
            (DatabaseError(resultCode: .init(rawValue: 255), message: secret, sql: secret), .sqliteOther),
            (POSIXError(.ENOSPC), .posixNoSpace),
            (CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: secret]), .cocoaReadPermission),
        ]
        for (error, expected) in cases {
            let diagnostic = Diagnostic(phase: .canonicalValidation, error: error)
            #expect(diagnostic.cause == expected)
            let encoded = try JSONEncoder().encode(diagnostic.failure)
            let output = diagnostic.logLine + String(decoding: encoded, as: UTF8.self)
            for marker in ["SYNTHETIC-SECRET", "/private", "example.wav", "forged-log-record", String(Int.max)] {
                #expect(!output.contains(marker))
            }
        }
    }

    @Test func onlyKnownDaemonCodesBecomeDiagnosticCauses() {
        let cases: [(String, Diagnostic.Cause)] = [
            ("model_not_loaded", .daemonModelNotLoaded),
            ("audio_load_failed", .daemonAudioLoadFailed),
            ("transcription_failed", .daemonTranscriptionFailed),
            ("socket_error", .daemonSocketError),
            ("transcribe_failed", .daemonTranscribeFailed),
            ("diarizer_unavailable", .daemonDiarizerUnavailable),
            ("diarize_failed", .daemonDiarizeFailed),
            ("model_not_loaded\nSYNTHETIC-SECRET", .clientTranscribeFailed),
            ("unexpected_private_code", .clientTranscribeFailed)
        ]
        for (code, expected) in cases {
            let diagnostic = Diagnostic(phase: .transcription,
                error: ClientError.transcribeFailed(code: code, message: "SYNTHETIC-SECRET"))
            #expect(diagnostic.cause == expected)
            #expect(!diagnostic.logLine.contains("SYNTHETIC-SECRET"))
            #expect(!diagnostic.logLine.contains("unexpected_private_code"))
        }
    }

    @Test func unknownErrorsAreNeverDescribedOrInspected() {
        for error: any Error in [UninspectableError(),
            UninspectableNSError(domain: "untrusted", code: 42),
            UninspectableNSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue),
            NSError(domain: "untrusted", code: Int.max, userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC-SECRET"])] {
            let diagnostic = Diagnostic(phase: .transcription, error: error)
            #expect(diagnostic.cause == .unknown)
            #expect(diagnostic.failure.code == "host.processing.transcription.unknown")
            #expect(!diagnostic.logLine.contains("untrusted"))
        }
    }

    @Test func diagnosticsDoNotChangeAutomaticRetryPolicy() {
        #expect(HarcHostProcessingWorker.isAutomaticallyRetryable(ClientError.daemonLaunchFailed("private")))
        #expect(HarcHostProcessingWorker.isAutomaticallyRetryable(UninspectableError()))
        #expect(HarcHostProcessingWorker.isAutomaticallyRetryable(CancellationError()))
        // Direct Host errors retain the old decision. The refresh boundary,
        // not their diagnostic classification, makes validation errors terminal.
        #expect(HarcHostProcessingWorker.isAutomaticallyRetryable(HarcHostError.canonicalHashMismatch))
        #expect(!HarcHostProcessingWorker.isAutomaticallyRetryable(StoreError.canonicalArtifactIdentityMismatch))
        #expect(!HarcHostProcessingWorker.isAutomaticallyRetryable(HostProcessingWorkerError.canonicalBindingChanged))
        for cause in Diagnostic.Cause.allCases {
            #expect(!HarcHostProcessingWorker.isAutomaticallyRetryable(
                HostProcessingWorkerError.canonicalRevalidationFailed(cause)))
        }
    }
}

private struct UninspectableError: LocalizedError, CustomNSError {
    var errorDescription: String? { Issue.record("Must not read localized description"); return "untrusted" }
    static var errorDomain: String { Issue.record("Must not bridge unknown errors"); return "untrusted" }
    var errorUserInfo: [String: Any] { Issue.record("Must not read errorUserInfo"); return [:] }
}

private final class UninspectableNSError: NSError, @unchecked Sendable {
    override var domain: String { Issue.record("Must not read arbitrary domain"); return "untrusted" }
    override var localizedDescription: String { Issue.record("Must not read localizedDescription"); return "untrusted" }
    override var userInfo: [String: Any] { Issue.record("Must not read userInfo"); return [:] }
}
