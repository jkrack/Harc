import AppKit
import SwiftUI

public enum ReadinessLevel: String, Codable, Sendable {
    case ready
    case degraded
    case blocked
    case optionalOff
    case checking
}

public enum ReadinessAction: String, Codable, Sendable {
    case chooseDestination
    case openMicrophonePrivacy
    case openScreenCapturePrivacy
    case installSTTModel
    case installSummarizer
    case openNotifications
    case openAccessibility
    case openRecoveryInbox

    var displayTitle: String {
        switch self {
        case .chooseDestination: return "Choose folder"
        case .openMicrophonePrivacy: return "Open microphone"
        case .openScreenCapturePrivacy: return "Open permissions"
        case .installSTTModel: return "Check setup"
        case .installSummarizer: return "Install model"
        case .openNotifications: return "Open notifications"
        case .openAccessibility: return "Open accessibility"
        case .openRecoveryInbox: return "Open recovery"
        }
    }
}

public struct CaptureReadinessItem: Identifiable, Equatable, Sendable {
    public enum ID: String, Codable, Sendable {
        case destination
        case microphone
        case systemAudio
        case localSTT
        case summarizer
        case speakerID
        case notifications
        case pastePermission
        case dictation
        case recovery
    }

    public var id: ID
    public var title: String
    public var detail: String
    public var level: ReadinessLevel
    public var action: ReadinessAction?

    public init(
        id: ID,
        title: String,
        detail: String,
        level: ReadinessLevel,
        action: ReadinessAction? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.level = level
        self.action = action
    }
}

public enum PermissionState: Equatable, Sendable {
    case allowed
    case denied
    case checking
}

public struct CaptureReadinessInput: Equatable, Sendable {
    public var destinationReady: Bool
    public var destinationText: String
    public var microphone: PermissionState
    public var microphoneText: String
    public var systemAudio: PermissionState
    public var systemAudioText: String
    public var localSTTReady: Bool
    public var localSTTText: String
    public var summarizerReady: Bool
    public var summarizerText: String
    public var speakerIDReady: Bool
    public var speakerIDText: String
    public var notificationsReady: Bool
    public var notificationsText: String
    public var pastePermissionReady: Bool
    public var pastePermissionText: String
    public var pendingRecoveryCount: Int

    public init(
        destinationReady: Bool,
        destinationText: String,
        microphone: PermissionState,
        microphoneText: String,
        systemAudio: PermissionState,
        systemAudioText: String,
        localSTTReady: Bool,
        localSTTText: String,
        summarizerReady: Bool,
        summarizerText: String,
        speakerIDReady: Bool,
        speakerIDText: String,
        notificationsReady: Bool,
        notificationsText: String,
        pastePermissionReady: Bool,
        pastePermissionText: String,
        pendingRecoveryCount: Int = 0
    ) {
        self.destinationReady = destinationReady
        self.destinationText = destinationText
        self.microphone = microphone
        self.microphoneText = microphoneText
        self.systemAudio = systemAudio
        self.systemAudioText = systemAudioText
        self.localSTTReady = localSTTReady
        self.localSTTText = localSTTText
        self.summarizerReady = summarizerReady
        self.summarizerText = summarizerText
        self.speakerIDReady = speakerIDReady
        self.speakerIDText = speakerIDText
        self.notificationsReady = notificationsReady
        self.notificationsText = notificationsText
        self.pastePermissionReady = pastePermissionReady
        self.pastePermissionText = pastePermissionText
        self.pendingRecoveryCount = pendingRecoveryCount
    }
}

public enum CaptureReadinessResolver {
    public static func resolve(_ input: CaptureReadinessInput) -> [CaptureReadinessItem] {
        var items: [CaptureReadinessItem] = [
            CaptureReadinessItem(
                id: .destination,
                title: "Destination",
                detail: input.destinationText,
                level: input.destinationReady ? .ready : .blocked,
                action: input.destinationReady ? nil : .chooseDestination
            ),
            permissionItem(
                id: .microphone,
                title: "Microphone",
                detail: input.microphoneText,
                permission: input.microphone,
                deniedLevel: .blocked,
                action: .openMicrophonePrivacy
            ),
            permissionItem(
                id: .systemAudio,
                title: "System Audio",
                detail: input.systemAudioText,
                permission: input.systemAudio,
                deniedLevel: .degraded,
                action: .openScreenCapturePrivacy
            ),
            CaptureReadinessItem(
                id: .localSTT,
                title: "STT",
                detail: input.localSTTText,
                level: input.localSTTReady ? .ready : .blocked,
                action: input.localSTTReady ? nil : .installSTTModel
            ),
            optionalItem(
                id: .summarizer,
                title: "Summaries",
                detail: input.summarizerText,
                ready: input.summarizerReady,
                action: .installSummarizer
            ),
            optionalItem(
                id: .speakerID,
                title: "Speaker ID",
                detail: input.speakerIDText,
                ready: input.speakerIDReady,
                action: nil
            ),
            optionalItem(
                id: .notifications,
                title: "Notifications",
                detail: input.notificationsText,
                ready: input.notificationsReady,
                action: .openNotifications
            ),
            optionalItem(
                id: .pastePermission,
                title: "Paste",
                detail: input.pastePermissionText,
                ready: input.pastePermissionReady,
                action: .openAccessibility
            ),
            dictationItem(input),
        ]

        if input.pendingRecoveryCount > 0 {
            items.append(
                CaptureReadinessItem(
                    id: .recovery,
                    title: "Recovery",
                    detail: "\(input.pendingRecoveryCount) recording recovery item\(input.pendingRecoveryCount == 1 ? "" : "s") pending",
                    level: .degraded,
                    action: .openRecoveryInbox
                )
            )
        }

        return items
    }

    public static func summary(for items: [CaptureReadinessItem]) -> String {
        if items.contains(where: { $0.level == .blocked }) {
            return "Recording blocked"
        }
        if items.contains(where: { $0.id == .recovery && $0.level != .ready }) {
            return "Recovery needed"
        }
        if items.contains(where: { $0.id == .systemAudio && $0.level == .degraded }) {
            return "Mic only"
        }
        if items.contains(where: { $0.level == .checking }) {
            return "Checking"
        }
        if items.contains(where: { $0.level == .degraded }) {
            return "Capture degraded"
        }
        if items.contains(where: { $0.level == .optionalOff }) {
            return "Capture ready"
        }
        return "Ready to record"
    }

    private static func permissionItem(
        id: CaptureReadinessItem.ID,
        title: String,
        detail: String,
        permission: PermissionState,
        deniedLevel: ReadinessLevel,
        action: ReadinessAction
    ) -> CaptureReadinessItem {
        switch permission {
        case .allowed:
            return CaptureReadinessItem(id: id, title: title, detail: detail, level: .ready)
        case .denied:
            return CaptureReadinessItem(id: id, title: title, detail: detail, level: deniedLevel, action: action)
        case .checking:
            return CaptureReadinessItem(id: id, title: title, detail: detail, level: .checking)
        }
    }

    private static func optionalItem(
        id: CaptureReadinessItem.ID,
        title: String,
        detail: String,
        ready: Bool,
        action: ReadinessAction?
    ) -> CaptureReadinessItem {
        CaptureReadinessItem(
            id: id,
            title: title,
            detail: detail,
            level: ready ? .ready : .optionalOff,
            action: ready ? nil : action
        )
    }

    /// Dictation readiness is derived: it needs local STT plus the
    /// Accessibility (paste) permission to insert at the cursor. Optional —
    /// a missing piece never makes core capture look blocked.
    private static func dictationItem(_ input: CaptureReadinessInput) -> CaptureReadinessItem {
        let ready = input.localSTTReady && input.pastePermissionReady
        let detail: String
        if ready {
            detail = "Hold the dictation hotkey and speak"
        } else if !input.localSTTReady {
            detail = "Needs local STT"
        } else {
            detail = "Needs Accessibility to insert text"
        }
        return CaptureReadinessItem(
            id: .dictation,
            title: "Dictation",
            detail: detail,
            level: ready ? .ready : .optionalOff,
            action: (!ready && input.localSTTReady) ? .openAccessibility : nil
        )
    }
}

enum LocalStackHealthState: Equatable {
    case ready
    case warning
    case muted

    init(readinessLevel: ReadinessLevel) {
        switch readinessLevel {
        case .ready:
            self = .ready
        case .degraded, .blocked, .checking:
            self = .warning
        case .optionalOff:
            self = .muted
        }
    }

    var iconName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .muted: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .muted: return .secondary
        }
    }
}

struct LocalStackHealthInput: Equatable {
    var destinationReady: Bool
    var destinationText: String
    var captureReady: Bool
    var captureText: String
    var systemAudioReady: Bool = true
    var systemAudioText: String = "System audio ready"
    var sttReady: Bool
    var sttText: String
    var summarizerReady: Bool
    var summarizerText: String
    var speakerIDReady: Bool
    var speakerIDText: String
    var notificationsReady: Bool
    var notificationsText: String
    var accessibilityReady: Bool
    var accessibilityText: String
    var pendingRecoveryCount: Int = 0
}

struct LocalStackHealthItem: Identifiable, Equatable {
    enum ID: String {
        case destination
        case capture
        case systemAudio
        case stt
        case summarizer
        case speakerID
        case notifications
        case accessibility
        case dictation
        case recovery
    }

    var id: ID
    var title: String
    var detail: String
    var state: LocalStackHealthState
    var fixTitle: String?
}

enum LocalStackHealthModel {
    enum Group: String, CaseIterable {
        case required
        case quality
        case afterRecording
        case dictation
        case recovery

        var title: String {
            switch self {
            case .required: return "Required for capture"
            case .quality: return "Quality"
            case .afterRecording: return "After recording"
            case .dictation: return "Dictation"
            case .recovery: return "Recovery"
            }
        }
    }

    static func items(for input: LocalStackHealthInput) -> [LocalStackHealthItem] {
        items(for: CaptureReadinessResolver.resolve(captureReadinessInput(for: input)))
    }

    static func items(for readinessItems: [CaptureReadinessItem]) -> [LocalStackHealthItem] {
        readinessItems.map { item in
            LocalStackHealthItem(
                id: localID(for: item.id),
                title: item.title,
                detail: item.detail,
                state: LocalStackHealthState(readinessLevel: item.level),
                fixTitle: item.action?.displayTitle
            )
        }
    }

    static func summary(for readinessItems: [CaptureReadinessItem]) -> String {
        CaptureReadinessResolver.summary(for: readinessItems)
    }

    static func summary(for items: [LocalStackHealthItem]) -> String {
        if items.contains(where: { ($0.id == .destination || $0.id == .capture || $0.id == .stt) && $0.state == .warning }) {
            return "Recording blocked"
        }
        if items.contains(where: { $0.id == .recovery && $0.state == .warning }) {
            return "Recovery needed"
        }
        if items.contains(where: { $0.id == .systemAudio && $0.state == .warning }) {
            return "Mic only"
        }
        if items.contains(where: { $0.state == .warning }) {
            return "Capture degraded"
        }
        if items.contains(where: { $0.state == .muted }) {
            return "Capture ready"
        }
        return "Ready to record"
    }

    static func group(for item: LocalStackHealthItem) -> Group {
        switch item.id {
        case .destination, .capture, .stt:
            return .required
        case .systemAudio, .speakerID:
            return .quality
        case .summarizer, .notifications, .accessibility:
            return .afterRecording
        case .dictation:
            return .dictation
        case .recovery:
            return .recovery
        }
    }

    static func groupedItems(_ items: [LocalStackHealthItem]) -> [(Group, [LocalStackHealthItem])] {
        Group.allCases.compactMap { group in
            let groupItems = items.filter { self.group(for: $0) == group }
            return groupItems.isEmpty ? nil : (group, groupItems)
        }
    }

    private static func captureReadinessInput(for input: LocalStackHealthInput) -> CaptureReadinessInput {
        CaptureReadinessInput(
            destinationReady: input.destinationReady,
            destinationText: input.destinationText,
            microphone: input.captureReady ? .allowed : .denied,
            microphoneText: input.captureText,
            systemAudio: input.systemAudioReady ? .allowed : .denied,
            systemAudioText: input.systemAudioText,
            localSTTReady: input.sttReady,
            localSTTText: input.sttText,
            summarizerReady: input.summarizerReady,
            summarizerText: input.summarizerText,
            speakerIDReady: input.speakerIDReady,
            speakerIDText: input.speakerIDText,
            notificationsReady: input.notificationsReady,
            notificationsText: input.notificationsText,
            pastePermissionReady: input.accessibilityReady,
            pastePermissionText: input.accessibilityText,
            pendingRecoveryCount: input.pendingRecoveryCount
        )
    }

    private static func localID(for id: CaptureReadinessItem.ID) -> LocalStackHealthItem.ID {
        switch id {
        case .destination: return .destination
        case .microphone: return .capture
        case .systemAudio: return .systemAudio
        case .localSTT: return .stt
        case .summarizer: return .summarizer
        case .speakerID: return .speakerID
        case .notifications: return .notifications
        case .pastePermission: return .accessibility
        case .dictation: return .dictation
        case .recovery: return .recovery
        }
    }
}

struct LocalStackHealthView: View {
    let items: [LocalStackHealthItem]
    var compact: Bool = false
    var onFix: (LocalStackHealthItem) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Local Stack", systemImage: "checklist.checked")
                        .font(compact ? .caption.weight(.semibold) : .headline)
                    Spacer()
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(summaryColor)
                }

                if compact {
                    ForEach(items) { item in
                        row(for: item)
                    }
                } else {
                    ForEach(LocalStackHealthModel.groupedItems(items), id: \.0) { group, groupItems in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(groupItems) { item in
                                row(for: item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(for item: LocalStackHealthItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.state.iconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.state.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let fixTitle = item.fixTitle {
                Button(fixTitle) { onFix(item) }
                    .font(.caption)
                    .buttonStyle(.plain)
            }
        }
    }

    private var summaryText: String {
        LocalStackHealthModel.summary(for: items)
    }

    private var summaryColor: Color {
        if items.contains(where: { $0.state == .warning }) { return .orange }
        if items.contains(where: { $0.state == .muted }) { return .secondary }
        return .green
    }
}
