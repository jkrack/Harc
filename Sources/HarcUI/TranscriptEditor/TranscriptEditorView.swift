import SwiftUI
import AppKit
import HarcStore

public struct TranscriptEditorView: View {
    @ObservedObject var vm: TranscriptEditorViewModel

    public init(vm: TranscriptEditorViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, HarcDesign.Space.md)
                .padding(.vertical, HarcDesign.Space.sm)

            if let err = vm.saveError {
                saveErrorBanner(err)
            }

            Divider().background(Color.harcOutlineVariant.opacity(0.3))

            TranscriptTextView(
                text: Binding(
                    get: { vm.editedText },
                    set: { vm.markEdited(newText: $0) }
                ),
                highlightRange: vm.currentHighlightRange,
                onCommandClick: { offset in vm.seekToWord(atCharOffset: offset) }
            )
            .background(Color.clear)

            if vm.wordIndexStale {
                staleHintBanner
            }

            Divider().background(Color.harcOutlineVariant.opacity(0.3))

            TranscriptEditorTransportView(vm: vm)
        }
    }

    private var titleBar: some View {
        HStack(spacing: HarcDesign.Space.sm) {
            if vm.isDirty {
                Circle()
                    .fill(Color.harcPrimary)
                    .frame(width: 8, height: 8)
            }
            Text(vm.recording.displayTitle)
                .font(HarcDesign.Font.titleLg)
                .foregroundStyle(Color.harcOnSurface)
                .lineLimit(1)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: vm.recording.wavPath)]
                )
            } label: {
                Image(systemName: "folder")
                Text("Reveal")
            }
            .buttonStyle(.plain)
            .font(HarcDesign.Font.bodyMd)
            .foregroundStyle(Color.harcOnSurfaceVariant)

            Button {
                Task { await vm.save() }
            } label: {
                Text("Save")
                    .font(HarcDesign.Font.bodyMd.weight(.semibold))
                    .foregroundStyle(vm.isDirty ? Color.harcPrimary : Color.harcOnSurfaceVariant)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!vm.isDirty)
        }
    }

    private var staleHintBanner: some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Text("Timestamps approximate after edits.")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, HarcDesign.Space.md)
        .padding(.vertical, HarcDesign.Space.xxs)
        .background(Color.harcOnSurfaceVariant.opacity(0.06))
    }

    private func saveErrorBanner(_ message: String) -> some View {
        HStack(spacing: HarcDesign.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harcError)
            Text(message)
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcError)
            Spacer()
        }
        .padding(.horizontal, HarcDesign.Space.md)
        .padding(.vertical, HarcDesign.Space.xs)
        .background(Color.harcError.opacity(0.08))
    }
}
