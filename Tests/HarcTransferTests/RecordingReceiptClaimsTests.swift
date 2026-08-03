import Foundation
import HarcDomain
import Testing
@testable import HarcTransfer

@Suite("Recording receipt transfer seam")
struct RecordingReceiptClaimsTests {
    @Test("claims derive manifest identity and reject zero cleanup-authorizing fields")
    func claimsAreStrict() throws {
        let manifest = TransferFixtures.manifestEvidence(
            uploadID: .random(),
            finalizedCapture: TransferFixtures.chunkedCapture()
        )
        let valid = try RecordingReceiptClaims(
            validatedManifest: manifest,
            canonicalRecordingID: CanonicalRecordingID(TransferFixtures.uuid(910)),
            canonicalRevision: .initial,
            changeCursor: ChangeCursor(1),
            receiptID: TransferFixtures.uuid(911),
            durableCommitTime: TransferFixtures.baseDate
        )
        #expect(valid.validatedManifest == manifest)

        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "canonicalRecordingID"
        )) {
            try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(zeroUUID),
                canonicalRevision: .initial,
                changeCursor: ChangeCursor(1),
                receiptID: TransferFixtures.uuid(911),
                durableCommitTime: TransferFixtures.baseDate
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "changeCursor")) {
            try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(TransferFixtures.uuid(910)),
                canonicalRevision: .initial,
                changeCursor: .zero,
                receiptID: TransferFixtures.uuid(911),
                durableCommitTime: TransferFixtures.baseDate
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(field: "receiptID")) {
            try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(TransferFixtures.uuid(910)),
                canonicalRevision: .initial,
                changeCursor: ChangeCursor(1),
                receiptID: zeroUUID,
                durableCommitTime: TransferFixtures.baseDate
            )
        }
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "durableCommitTime"
        )) {
            try RecordingReceiptClaims(
                validatedManifest: manifest,
                canonicalRecordingID: CanonicalRecordingID(TransferFixtures.uuid(910)),
                canonicalRevision: .initial,
                changeCursor: ChangeCursor(1),
                receiptID: TransferFixtures.uuid(911),
                durableCommitTime: Date(timeIntervalSince1970: 0)
            )
        }
    }

    @Test("receipt evidence cannot claim a non-pending processing state")
    func evidenceRequiresPendingProcessing() throws {
        let manifest = TransferFixtures.manifestEvidence(
            uploadID: .random(),
            finalizedCapture: TransferFixtures.chunkedCapture()
        )
        #expect(throws: TransferValidationError.evidenceBindingMismatch(
            field: "processingState"
        )) {
            try ValidatedRecordingReceiptEvidence(
                hostTrust: manifest.hostTrust,
                exactReceiptObject: TransferFixtures.exactObject(
                    .recordingReceiptV1,
                    byte: 0x51
                ),
                validatedManifest: manifest,
                uploadID: manifest.uploadID,
                originRecordingID: manifest.originRecordingID,
                signedManifestObjectSHA256: manifest.exactManifestObject.objectSHA256,
                canonicalPCMSHA256: manifest.canonicalPCMSHA256,
                totalCanonicalFrames: manifest.totalCanonicalFrames,
                canonicalFormat: manifest.canonicalFormat,
                canonicalRecordingID: CanonicalRecordingID(TransferFixtures.uuid(912)),
                canonicalRevision: .initial,
                changeCursor: ChangeCursor(1),
                receiptID: TransferFixtures.uuid(913),
                durableCommitTime: TransferFixtures.baseDate,
                processingState: .ready
            )
        }
    }

    private var zeroUUID: UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
