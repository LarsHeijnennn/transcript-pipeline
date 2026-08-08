import SwiftData
import SwiftUI

struct RecordingChatView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var environment: AppEnvironment

    let recording: RecordingRecord
    let player: AudioPlayerController
    let isProcessing: Bool
    let onProcess: () -> Void
    @State private var question = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if recording.chatMessages.isEmpty {
                VStack(spacing: 18) {
                    ContentUnavailableView(
                        "Ask this recording",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(recording.segments.isEmpty
                            ? "Process the recording first. Answers will use only its transcript."
                            : "Answers use only the current transcript and link back to supporting moments.")
                    )
                    if recording.segments.isEmpty {
                        Button("Process Recording", action: onProcess)
                            .liquidGlassButton(prominent: true)
                            .disabled(isProcessing)
                    } else {
                        LiquidGlassGroup(spacing: 8) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { suggestionButtons }
                                VStack(spacing: 8) { suggestionButtons }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(recording.sortedChatMessages) { message in
                                ChatBubble(message: message) { citation in
                                    player.seek(to: citation.startSeconds)
                                }
                                .id(message.id)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: recording.chatMessages.count) { _, _ in
                        if let last = recording.sortedChatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            if isSending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding an answer in the transcript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .accessibilityElement(children: .combine)
            }
            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMessage).font(.caption)
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
            }
            LiquidGlassGroup(spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask about this recording", text: $question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($composerIsFocused)
                        .onSubmit { submit() }
                    Button(action: submit) {
                        if isSending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up") }
                    }
                    .liquidGlassButton(prominent: true)
                    .disabled(question.trimmed.isEmpty || isSending || recording.segments.isEmpty)
                }
                .padding(14)
                .functionalGlass(cornerRadius: AppStyle.floatingRadius)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        ForEach(suggestionPrompts, id: \.self) { prompt in
            Button(prompt) {
                question = prompt
                composerIsFocused = true
            }
                .liquidGlassButton()
                .controlSize(.small)
        }
    }

    private var suggestionPrompts: [String] {
        ["What was decided?", "List the action items", "What remains unclear?"]
    }

    private func submit() {
        let submitted = question.trimmed
        guard !submitted.isEmpty else { return }
        question = ""
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await environment.processing.sendQuestion(
                    submitted,
                    recording: recording,
                    insightModel: settings.resolvedInsightModel,
                    modelContext: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
                question = submitted
                composerIsFocused = true
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessageRecord
    let onSeek: (EvidenceCitation) -> Void

    var body: some View {
        HStack {
            if message.role == .assistant { bubble; Spacer(minLength: 80) }
            else { Spacer(minLength: 80); bubble }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.content).textSelection(.enabled)
            if !message.citations.isEmpty {
                CitationButtons(citations: message.citations, onSeek: onSeek)
            }
        }
        .padding(12)
        .contentSurface(
            cornerRadius: 16,
            tint: message.role == .user ? .accentColor : nil
        )
        .frame(maxWidth: 620, alignment: .leading)
    }
}
