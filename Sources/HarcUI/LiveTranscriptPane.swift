import SwiftUI

/// The transcript as it accumulates during a recording.
///
/// `AppDelegate` has always piped chunk results into
/// `RecordingState.livePreviewText` — the task that does it is even commented
/// "Pipe transcript updates into the UI" — but nothing read the property, so
/// the Library showed "No Item Selected" through a 45-minute meeting while a
/// complete transcript sat in memory a few feet away.
///
/// This is deliberately not a live caption feed. Chunks land roughly once a
/// minute, so the text arrives a paragraph at a time; the product's stance
/// that reliability beats latency is about not chasing word-by-word output,
/// not about hiding the work. Seeing paragraphs appear is what tells you the
/// recording is being transcribed rather than merely being recorded.
struct LiveTranscriptPane: View {
    @ObservedObject var recordingState: RecordingState
    /// Seconds since the last chunk landed, from the bridge's transcript
    /// clock. Nil when nothing has landed yet.
    let lastUpdateAge: String?

    private var transcript: String {
        recordingState.livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if transcript.isEmpty {
                waitingState
            } else {
                transcriptScroll
            }
        }
    }

    private var header: some View {
        HStack(spacing: HarcSpacing.sm) {
            Circle()
                .fill(HarcBrand.live)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.harcTitle)
            // TimelineView rather than a Timer: the pane only exists while
            // recording, so its clock should start and stop with it.
            if let start = recordingState.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ElapsedFormatter.string(since: start, now: context.date))
                        .font(.harcLabel.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let lastUpdateAge {
                Text(lastUpdateAge)
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, HarcSpacing.xl)
        .padding(.vertical, HarcSpacing.md)
    }

    /// Before the first chunk there is genuinely nothing to show, and silence
    /// there reads as "transcription isn't running". Say what is happening and
    /// roughly when the first text will appear.
    private var waitingState: some View {
        VStack(spacing: HarcSpacing.md) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Transcribing as you record")
                .font(.harcTitle.weight(.semibold))
            Text("Text appears within a few seconds and firms up as each chunk finishes. The full transcript is saved when you stop.")
                .font(.harcBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(transcript)
                    .font(.harcBody)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HarcSpacing.xl)
                    .id(Self.bottomAnchor)
            }
            // Follow the text as it grows; the interesting end of a live
            // transcript is always the newest one.
            .onChange(of: recordingState.livePreviewText) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "harc.live.transcript.bottom"
}
