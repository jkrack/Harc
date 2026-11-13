import Foundation

extension HarcAppBridge {
    /// One explicit local request. This callback is wired only to the resident
    /// runtime's read-only API, never to either repair or migration action.
    public func requestHostReceiptInspection() async {
        guard !hostReceiptInspectionInProgress else { return }
        guard hostRuntimeReady, !hostReceiptRepairInProgress,
              !hostLibraryMigrationInProgress else {
            hostReceiptInspectionStatus = "Inspection is unavailable while the Host is offline or another verification is running."
            hostReceiptInspectedID = nil
            return
        }
        let input = hostReceiptInspectionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: input) else {
            hostReceiptInspectionStatus = hostReceiptInspectionUsesUploadID ? "Enter a valid upload ID." : "Enter a valid canonical recording ID."
            hostReceiptInspectedID = nil
            return
        }
        hostReceiptInspectionInProgress = true
        hostReceiptInspectionStatus = nil
        hostReceiptInspectedID = id
        defer { hostReceiptInspectionInProgress = false }
        do {
            hostReceiptInspectionStatus = try await (hostReceiptInspectionUsesUploadID
                ? inspectHostPublicationBinding(id) : inspectHostReceiptBinding(id))
        } catch is CancellationError {
            hostReceiptInspectionStatus = "Inspection cancelled. No repair was requested."
        } catch {
            // Do not display raw errors, which may carry paths or credentials.
            hostReceiptInspectionStatus = "Inspection could not finish. No repair was requested."
        }
    }
}
