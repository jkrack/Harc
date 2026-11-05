import HarcHost

/// Deliberately formats only the diagnostic's bounded fields. Raw errors,
/// local paths and signed evidence never enter the Settings result.
enum HarcHostReceiptInspectionPresentation {
    static func message(_ report: HostReceiptBindingDiagnostic) -> String {
        let headline: String
        switch report.outcome {
        case .verifiedCurrentBinding:
            headline = "Stored identity, audio and signed evidence match."
        case .verifiedMetadataDrift:
            headline = "Audio and signed evidence verify, but filesystem metadata differs from the stored binding."
        case .notFound:
            headline = "No committed receipt was found for this recording."
        case .blocked:
            headline = "Inspection stopped at \(report.failureStage.map(stageName) ?? "an unavailable stage")."
        }
        var lines = [headline]
        if !report.completedStages.isEmpty {
            lines.append("Checked: " + report.completedStages.map(stageName).joined(separator: ", ") + ".")
        }
        if let code = report.failureCode { lines.append("Diagnostic code: " + code) }
        if !report.identityChanges.isEmpty {
            lines.append("Changed identity fields: " + report.identityChanges.map(\.rawValue).joined(separator: ", ") + ".")
        }
        lines.append("Read-only inspection; no repair, processing or cleanup was requested.")
        return lines.joined(separator: "\n")
    }

    private static func stageName(_ stage: HostReceiptBindingDiagnostic.Stage) -> String {
        switch stage {
        case .receiptState: "stored receipt"
        case .publicationActivity: "publication activity"
        case .trustedPath: "retained directory binding"
        case .filesystemIdentity: "filesystem identity"
        case .canonicalAudio: "complete canonical audio"
        case .manifestEvidence: "signed manifest and stored bindings"
        case .receiptEvidence: "signed receipt"
        case .snapshotRecheck: "final snapshot and binding recheck"
        }
    }
}
