import Foundation
import HarcClientStore
import HarcDomain
import HarcTransfer
import HarcUI

/// Filesystem-to-store reconciliation for the private desktop Client archive.
/// It repairs only facts Harc can prove from an owned canonical WAV, a valid
/// sidecar, or an existing immutable outbox. Conflicts stay untouched.
enum HarcDesktopClientRecovery {
    struct LocalCandidate: Sendable {
        let masterURL: URL
        let sidecarURL: URL
        let sidecar: HarcDesktopClientCaptureSidecar
    }

    struct Outcome: Sendable {
        let report: ClientRecoverSyncReport
        let blockedOrigins: Set<OriginRecordingID>
        let localCandidates: [LocalCandidate]
    }

    static func reconcile(
        root: URL,
        store: HarcTransferStore,
        deviceID: DeviceID
    ) throws -> Outcome {
        let directory = root.appendingPathComponent("Captures", isDirectory: true)
        try HarcDesktopClientFiles.requireDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let masterPairs: [(String, URL)] = files.compactMap { url in
            guard url.pathExtension.lowercased() == "wav" else { return nil }
            return (url.deletingPathExtension().lastPathComponent.lowercased(), url)
        }
        let masters = Dictionary<String, URL>(uniqueKeysWithValues: masterPairs)
        let sidecarPairs: [(String, URL)] = files.compactMap { url in
            let suffix = ".capture.json"
            guard url.lastPathComponent.lowercased().hasSuffix(suffix) else {
                return nil
            }
            return (String(url.lastPathComponent.dropLast(suffix.count)).lowercased(), url)
        }
        let sidecars = Dictionary<String, URL>(uniqueKeysWithValues: sidecarPairs)

        let originalOutboxes = try store.recordingOutboxes()
        let originalByStem = Dictionary(uniqueKeysWithValues: originalOutboxes.map {
            ($0.finalizedCapture.capture.originRecordingID.recordingUUID.uuidString.lowercased(), $0)
        })
        var sidecarsRebuilt = 0
        var outboxesRepaired = 0
        var alreadyTracked = 0
        var blockedOrigins = Set<OriginRecordingID>()
        var localCandidates: [LocalCandidate] = []
        var issues: [ClientRecoverSyncIssue] = []

        for stem in Set(masters.keys).union(sidecars.keys).sorted() {
            guard let recordingUUID = UUID(uuidString: stem) else {
                issues.append(issue(stem, "The capture filename is not a recording identifier. It was left untouched."))
                continue
            }
            let masterURL = masters[stem]
            let sidecarURL = sidecars[stem]
            do {
                if let sidecarURL {
                    guard let masterURL else {
                        throw RecoveryError.missingMaster
                    }
                    let sidecar = try decodeSidecar(sidecarURL)
                    try validate(
                        sidecar: sidecar,
                        recordingUUID: recordingUUID,
                        masterURL: masterURL,
                        deviceID: deviceID
                    )
                    let existed = try store.recordingOutbox(
                        for: sidecar.capture.originRecordingID
                    ) != nil
                    _ = try store.persistFinalizedCapture(
                        sidecar.capture,
                        masterFileURL: masterURL,
                        persistedAt: sidecar.persistedAt
                    )
                    localCandidates.append(LocalCandidate(
                        masterURL: masterURL,
                        sidecarURL: sidecarURL,
                        sidecar: sidecar
                    ))
                    if existed { alreadyTracked += 1 } else { outboxesRepaired += 1 }
                    continue
                }

                guard let masterURL else { continue }
                if let existing = originalByStem[stem] {
                    try validate(existing: existing, masterURL: masterURL, deviceID: deviceID)
                    let rebuilt = HarcDesktopClientCaptureSidecar(
                        capture: existing.finalizedCapture.capture,
                        transcript: nil,
                        speakerEmbeddings: nil,
                        persistedAt: existing.finalizedCapture.persistedAt
                    )
                    try HarcDesktopClientFiles.writeSidecar(
                        rebuilt,
                        to: directory.appendingPathComponent("\(stem).capture.json")
                    )
                    localCandidates.append(LocalCandidate(
                        masterURL: masterURL,
                        sidecarURL: directory.appendingPathComponent("\(stem).capture.json"),
                        sidecar: rebuilt
                    ))
                    sidecarsRebuilt += 1
                    alreadyTracked += 1
                } else {
                    let rebuilt = try rebuildOrphanedCapture(
                        recordingUUID: recordingUUID,
                        masterURL: masterURL,
                        deviceID: deviceID
                    )
                    let rebuiltURL = directory.appendingPathComponent("\(stem).capture.json")
                    try HarcDesktopClientFiles.writeSidecar(rebuilt, to: rebuiltURL)
                    _ = try store.persistFinalizedCapture(
                        rebuilt.capture,
                        masterFileURL: masterURL,
                        persistedAt: rebuilt.persistedAt
                    )
                    localCandidates.append(LocalCandidate(
                        masterURL: masterURL,
                        sidecarURL: rebuiltURL,
                        sidecar: rebuilt
                    ))
                    sidecarsRebuilt += 1
                    outboxesRepaired += 1
                }
            } catch {
                blockedOrigins.insert(
                    OriginRecordingID(deviceID: deviceID, recordingUUID: recordingUUID)
                )
                issues.append(issue(stem, recoveryMessage(for: error)))
            }
        }

        let reconciled = try store.recordingOutboxes()
        var retryRequested = 0
        var alreadyOnHost = 0
        var securityBlocked = blockedOrigins.count
        for outbox in reconciled {
            let capture = outbox.finalizedCapture
            let stem = capture.capture.originRecordingID.recordingUUID.uuidString.lowercased()
            if blockedOrigins.contains(capture.capture.originRecordingID) {
                continue
            }
            guard FileManager.default.fileExists(atPath: capture.masterFileURL.path),
                  capture.masterFileState == .present else {
                blockedOrigins.insert(capture.capture.originRecordingID)
                securityBlocked += 1
                issues.append(issue(stem, "The durable audio master is missing. Transfer was not retried."))
                continue
            }
            if outbox.integrityBlock != nil
                || outbox.stateMachine.state == .securityBlocked {
                securityBlocked += 1
            } else if outbox.stateMachine.state == .committed {
                alreadyOnHost += 1
            } else {
                retryRequested += 1
            }
        }

        return Outcome(
            report: ClientRecoverSyncReport(
                mastersFound: masters.count,
                sidecarsFound: sidecars.count,
                sidecarsRebuilt: sidecarsRebuilt,
                outboxesRepaired: outboxesRepaired,
                alreadyTracked: alreadyTracked,
                retryRequested: retryRequested,
                alreadyOnHost: alreadyOnHost,
                securityBlocked: securityBlocked,
                issues: deduplicated(issues)
            ),
            blockedOrigins: blockedOrigins,
            localCandidates: localCandidates.sorted {
                $0.sidecar.capture.captureStartedAt
                    < $1.sidecar.capture.captureStartedAt
            }
        )
    }

    private static func decodeSidecar(
        _ url: URL
    ) throws -> HarcDesktopClientCaptureSidecar {
        do {
            return try JSONDecoder().decode(
                HarcDesktopClientCaptureSidecar.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
        } catch {
            throw RecoveryError.invalidSidecar
        }
    }

    private static func validate(
        sidecar: HarcDesktopClientCaptureSidecar,
        recordingUUID: UUID,
        masterURL: URL,
        deviceID: DeviceID
    ) throws {
        guard sidecar.capture.producingDeviceID == deviceID,
              sidecar.capture.originRecordingID.deviceID == deviceID else {
            throw RecoveryError.identityMismatch
        }
        guard sidecar.capture.originRecordingID.recordingUUID == recordingUUID else {
            throw RecoveryError.filenameConflict
        }
        let inspected = try HarcDesktopClientFiles.inspectCanonicalWAV(masterURL)
        guard inspected.frames == sidecar.capture.totalCanonicalFrames,
              inspected.pcmSHA256 == sidecar.capture.canonicalPCMSHA256.rawBytes else {
            throw RecoveryError.audioConflict
        }
    }

    private static func validate(
        existing: StoredRecordingOutbox,
        masterURL: URL,
        deviceID: DeviceID
    ) throws {
        let capture = existing.finalizedCapture.capture
        guard capture.producingDeviceID == deviceID,
              capture.originRecordingID.deviceID == deviceID else {
            throw RecoveryError.identityMismatch
        }
        guard existing.finalizedCapture.masterFileURL.standardizedFileURL
                == masterURL.standardizedFileURL else {
            throw RecoveryError.filenameConflict
        }
        let inspected = try HarcDesktopClientFiles.inspectCanonicalWAV(masterURL)
        guard inspected.frames == capture.totalCanonicalFrames,
              inspected.pcmSHA256 == capture.canonicalPCMSHA256.rawBytes else {
            throw RecoveryError.audioConflict
        }
    }

    private static func rebuildOrphanedCapture(
        recordingUUID: UUID,
        masterURL: URL,
        deviceID: DeviceID
    ) throws -> HarcDesktopClientCaptureSidecar {
        let prepared = try HarcDesktopClientFiles.inspectCanonicalWAV(masterURL)
        let product = prepared.frames.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { throw RecoveryError.invalidDuration }
        let durationNanoseconds = product.partialValue / 16_000
        let duration = Double(prepared.frames) / 16_000
        let values = try masterURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )
        let endedAt = values.contentModificationDate ?? values.creationDate ?? Date()
        let startedAt = endedAt.addingTimeInterval(-duration)
        let origin = OriginRecordingID(deviceID: deviceID, recordingUUID: recordingUUID)
        let capture = try FinalizedCapture(
            producingDeviceID: deviceID,
            originRecordingID: origin,
            captureStartedAt: startedAt,
            captureEndedAt: endedAt,
            captureStartedMonotonicNanoseconds: 0,
            captureEndedMonotonicNanoseconds: durationNanoseconds,
            finalizationReason: .recoveredDurablePrefix,
            totalCanonicalFrames: prepared.frames,
            totalCanonicalBytes: prepared.frames * 2,
            canonicalPCMSHA256: try CanonicalPCMHash(prepared.pcmSHA256),
            discontinuities: []
        )
        return HarcDesktopClientCaptureSidecar(
            capture: capture,
            transcript: nil,
            speakerEmbeddings: nil,
            persistedAt: endedAt
        )
    }

    private static func issue(
        _ stem: String,
        _ message: String
    ) -> ClientRecoverSyncIssue {
        let recording = stem.count > 8 ? String(stem.prefix(8)) : stem
        return ClientRecoverSyncIssue(
            id: "\(stem):\(message)",
            recording: recording,
            message: message
        )
    }

    private static func deduplicated(
        _ issues: [ClientRecoverSyncIssue]
    ) -> [ClientRecoverSyncIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }

    private static func recoveryMessage(for error: Error) -> String {
        if let error = error as? RecoveryError {
            return error.errorDescription ?? "Recovery could not verify this recording."
        }
        return error.localizedDescription
    }
}

/// Coalesces recovery requests without losing one that arrives while a pass is
/// active. Multiple overlapping requests become exactly one follow-up pass.
struct HarcDesktopClientRecoveryRequestGate {
    private(set) var isRunning = false
    private var followUpRequested = false

    mutating func request() -> Bool {
        guard !isRunning else {
            followUpRequested = true
            return false
        }
        isRunning = true
        return true
    }

    mutating func finish() -> Bool {
        isRunning = false
        let shouldRunAgain = followUpRequested
        followUpRequested = false
        return shouldRunAgain
    }

    mutating func reset() {
        isRunning = false
        followUpRequested = false
    }
}

private enum RecoveryError: LocalizedError {
    case missingMaster
    case invalidSidecar
    case identityMismatch
    case filenameConflict
    case audioConflict
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .missingMaster:
            "The metadata exists but its durable audio master is missing."
        case .invalidSidecar:
            "The capture metadata is unreadable. It was left untouched."
        case .identityMismatch:
            "The capture belongs to a different Client identity. It was security blocked and left untouched."
        case .filenameConflict:
            "The capture filename conflicts with its durable identity. It was left untouched."
        case .audioConflict:
            "The audio does not match its durable capture facts. It was left untouched."
        case .invalidDuration:
            "The recovered audio duration cannot be represented safely."
        }
    }
}
