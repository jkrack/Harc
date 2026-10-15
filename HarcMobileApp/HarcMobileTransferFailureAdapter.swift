import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcDomain
import HarcTransfer

enum HarcMobileTransferError: Error {
    case notPaired
    case codecNotQualified
}

enum HarcMobileHostSessionConnectorError: LocalizedError {
    case notPaired
    case pairingRepairRequired

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "This iPhone is not paired with a Harc Host."
        case .pairingRepairRequired:
            "The Host no longer accepts this iPhone’s saved pairing. Recordings are safe on this iPhone. Forget this Host, create a new invitation, and pair again."
        }
    }
}

enum HarcMobileTransferFailurePresentation: Equatable {
    case cancelled
    case waitingForPairing
    case codecQualificationRequired
    case securityBlocked(String)
    case retryNeeded(String)
}

/// The production error adapter both reports UI state and determines whether
/// this queue pass may continue. Tests call this same handler, without a socket.
enum HarcMobileTransferFailureAdapter {
    static func handle(
        _ error: any Error, origin: OriginRecordingID, store: HarcTransferStore,
        report: (HarcMobileTransferFailurePresentation) -> Void,
        persistenceFailure: (any Error) -> Void = { _ in }
    ) throws {
        if error is CancellationError {
            report(.cancelled)
            throw error
        }
        if let transfer = error as? HarcMobileTransferError {
            switch transfer {
            case .notPaired: report(.waitingForPairing)
            case .codecNotQualified: report(.codecQualificationRequired)
            }
            throw error
        }
        if let connector = error as? HarcMobileHostSessionConnectorError {
            switch connector {
            case .notPaired:
                report(.waitingForPairing)
            case .pairingRepairRequired:
                do { try persistPairingRepairBlock(origin: origin, store: store) }
                catch { persistenceFailure(error) }
                report(.securityBlocked(connector.localizedDescription))
            }
            throw error
        }
        if let encoding = error as? HarcMobileALACEncodingError {
            // encodingFailed includes per-file writes and buffer failures. It
            // does not change the compile-time codec qualification gate. Keep
            // this master for retry and allow unrelated recordings to proceed.
            if case .encodingFailed = encoding {
                report(.retryNeeded("This recording couldn't be prepared for transfer. Your audio is saved on this iPhone. Try again."))
            } else {
                report(.retryNeeded(diagnosticMessage(error)))
            }
            return
        }
        let outbox = try? store.recordingOutbox(for: origin)
        if outbox?.stateMachine.state == .securityBlocked {
            report(.securityBlocked(diagnosticMessage(error)))
        } else {
            report(.retryNeeded(diagnosticMessage(error)))
        }
    }

    static func diagnosticMessage(_ error: any Error) -> String {
        let reflected = String(reflecting: error)
        return reflected.isEmpty ? error.localizedDescription : reflected
    }

    private static func persistPairingRepairBlock(
        origin: OriginRecordingID, store: HarcTransferStore
    ) throws {
        _ = try store.updateRecordingOutbox(for: origin) { machine in
            switch machine.state {
            case .localOnly:
                try machine.queue()
                try machine.beginAuthorization()
                try machine.blockForSecurity(.grantRevoked)
            case .queued:
                try machine.beginAuthorization()
                try machine.blockForSecurity(.grantRevoked)
            case .failedRecoverable:
                try machine.retryRecoverable()
                try machine.beginAuthorization()
                try machine.blockForSecurity(.grantRevoked)
            case .authorizing, .activeUpload, .backgroundScheduled, .hostCommitPending:
                try machine.blockForSecurity(.grantRevoked)
            case .securityBlocked, .committed:
                break
            }
        }
    }
}
