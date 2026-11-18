import SwiftUI
import HarcStore
import HarcDomain

/// Explicit single-source producer entry. Never launches from view appearance,
/// scans the Library, or interprets an inferred connection as an assignment.
struct ProjectMentionConsentView: View {
    let store: RecordingStore
    let host: LibraryMetadata
    let source: Recording?
    let canWrite: @MainActor () -> Bool
    let onProduced: () -> Void
    @State private var projects: [KnowledgeProject] = []
    @State private var projectID: UUID?
    @State private var newName = ""
    @State private var consentKey: ProjectMentionConsentKey?
    @State private var projectLoad = ProjectMentionLoadGeneration()
    @State private var busy = false
    @State private var feedback: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("Find a connection in the selected recording") {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                if let source, source.id != nil {
                    Text("Source: \(source.displayTitle)").font(.harcLabel)
                        .accessibilityIdentifier("projectMention.source")
                    Text("Only this recording’s transcript will be checked on this Mac. Case-sensitive, exact project-name mentions become suggestions, not assignments. Other recordings and audio are not scanned.")
                        .font(.harcBody)
                    Picker("Knowledge project", selection: $projectID) {
                        Text("Choose a project").tag(nil as UUID?)
                        ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("New project name (3–120 characters)", text: $newName)
                        .accessibilityIdentifier("projectMention.newProject")
                    Button("Create project") { createProject() }
                        .accessibilityIdentifier("projectMention.create")
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || newName.count > 120)
                    Toggle("Check this transcript for the selected project name", isOn: Binding(get: { hasConsent }, set: { consentKey = $0 ? selectionKey : nil }))
                        .accessibilityIdentifier("projectMention.consent")
                    Button("Find name mentions") { produce() }
                        .accessibilityIdentifier("projectMention.find")
                        .disabled(!hasConsent || projectID == nil)
                    Text("First 100 projects shown. A name mention does not prove this recording belongs to that project.")
                        .font(.harcCaption)
                } else {
                    Text("Select a recording in the Library, then reopen Connections to choose that source.")
                }
                if let feedback { Text(feedback).font(.harcBody).textSelection(.enabled) }
                if busy { ProgressView("Working locally…") }
            }
            // Preserve the source/consent disclosure and receipts at their
            // natural height; the review list below can scroll instead.
            .fixedSize(horizontal: false, vertical: true)
            .disabled(busy || !canWrite())
        }
        .disclosureGroupStyle(ProjectMentionDisclosureStyle())
        .padding(.horizontal, HarcSpacing.lg)
        .task { await loadProjects() }
        .onChange(of: selectionKey) { _, _ in consentKey = nil }
        .onDisappear { operation?.cancel() }
    }

    private var selectionKey: ProjectMentionConsentKey? {
        guard let source, let id = source.id, let projectID,
              let project = projects.first(where: { $0.id == projectID }) else { return nil }
        return ProjectMentionConsentKey(recordingID: id, canonicalID: source.canonicalID,
            libraryID: host.libraryID, writerMode: host.writerMode, authority: host.hostAuthorityID,
            hostState: host.hostStateID, projectID: project.id, projectVersion: project.version)
    }
    private var hasConsent: Bool { selectionKey != nil && consentKey == selectionKey }

    @MainActor private func loadProjects() async {
        let generation = projectLoad.begin()
        do {
            let loaded = try await store.knowledgeProjectsForReview(expectedHost: host)
            guard !Task.isCancelled, projectLoad.isCurrent(generation) else { return }
            projects = loaded
        } catch {
            guard projectLoad.isCurrent(generation) else { return }
            feedback = "Projects are unavailable. Reopen Connections on the active Host."
        }
    }

    @MainActor private func createProject() {
        guard !busy, canWrite() else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...120).contains(name.count) else { return }
        busy = true
        // Invalidate a prior appearance read before awaiting creation, so it
        // cannot replace the newly created picker entry after this task returns.
        _ = projectLoad.begin()
        operation = Task {
            defer { busy = false }
            do {
                let project = try await store.createKnowledgeProject(name: name, expectedHost: host)
                await loadProjects()
                if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
                projectID = project.id; newName = ""; consentKey = nil
                feedback = "Project created. Choose whether to check the selected transcript."
            } catch { feedback = "Could not create the project on the active Host." }
        }
    }

    @MainActor private func produce() {
        guard !busy, hasConsent, canWrite(), let source, let id = source.id, let projectID,
              let project = projects.first(where: { $0.id == projectID }) else { return }
        busy = true
        operation = Task {
            defer { busy = false; consentKey = nil }
            do {
                let batch = try await store.prepareProjectMentionProposals(recordingIDs: [id], projectID: projectID, expectedHost: host,
                    expectedCanonicalIDs: [id: source.canonicalID], expectedProjectVersion: project.version)
                try Task.checkCancellation()
                guard canWrite() else { throw ProjectRefinementError.hostUnavailable }
                let result = try await store.commitProjectMentionProposals(batch)
                feedback = "\(result.inserted) new suggestions; \(result.existing) existing answers or suggestions preserved. \(batch.noMatchCount) without an exact name mention; \(batch.oversizedCount) too large; \(batch.unavailableCount + result.stale) unavailable or changed. No assignments made."
                onProduced()
            } catch is CancellationError {
                feedback = "Stopped. Reopen Connections to see any completed results."
            } catch { feedback = "Could not check this source. Reopen Connections on the active Host." }
        }
    }
}


struct ProjectMentionConsentKey: Equatable {
    let recordingID: Int64
    let canonicalID: CanonicalRecordingID
    let libraryID: LibraryID
    let writerMode: LibraryWriterMode
    let authority: HostAuthorityID?
    let hostState: HostStateID?
    let projectID: UUID
    let projectVersion: UUID
}

struct ProjectMentionLoadGeneration {
    private var current = UUID()
    mutating func begin() -> UUID { current = UUID(); return current }
    func isCurrent(_ value: UUID) -> Bool { current == value }
}

/// The entire source-disclosure label is an ordinary keyboard-accessible button.
/// Keep the native DisclosureGroup state; opening it does not grant consent.
private struct ProjectMentionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.md) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projectMention.disclosure")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
