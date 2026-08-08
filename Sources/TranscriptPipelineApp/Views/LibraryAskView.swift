import SwiftUI

struct LibraryAskView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    let recordings: [RecordingRecord]
    let onOpenSource: (LibrarySourceCitation) -> Void

    @State private var question = ""
    @State private var messages: [LibraryConversationEntry] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AppCanvas()
            VStack(spacing: 0) {
                header
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label("Ask across your library", systemImage: "books.vertical")
                    } description: {
                        Text("Relevant excerpts are selected on this Mac. Only those excerpts and your question are sent to OpenAI.")
                    } actions: {
                        ViewThatFits(in: .horizontal) {
                            HStack { suggestionButtons }
                            VStack { suggestionButtons }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                ForEach(messages) { message in
                                    LibraryConversationRow(message: message, onOpenSource: onOpenSource)
                                        .id(message.id)
                                }
                            }
                            .padding(22)
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                }
                if let errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(errorMessage).font(.caption)
                        Spacer()
                        Button("Dismiss") { self.errorMessage = nil }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 22)
                }
                composer
            }
        }
        .navigationTitle("Ask Library")
    }

    private var header: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "books.vertical", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Library intelligence").font(.title2.weight(.semibold))
                Text("Local retrieval · \(recordings.filter { !$0.segments.isEmpty }.count) searchable recordings · no full-library upload")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !messages.isEmpty {
                Button("Clear", systemImage: "trash") { messages.removeAll() }
                    .liquidGlassButton()
            }
        }
        .padding(18)
        .functionalGlass(cornerRadius: 20)
        .padding(14)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask across all processed recordings", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                if isSending { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.up") }
            }
            .liquidGlassButton(prominent: true)
            .disabled(question.trimmed.isEmpty || isSending || recordings.allSatisfy(\.segments.isEmpty))
        }
        .padding(14)
        .functionalGlass(cornerRadius: AppStyle.floatingRadius)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        ForEach(["What decisions recur?", "What tasks are still open?", "Summarize a recurring topic"], id: \.self) { prompt in
            Button(prompt) { question = prompt; focused = true }
                .liquidGlassButton()
        }
    }

    private func submit() {
        let submitted = question.trimmed
        guard !submitted.isEmpty else { return }
        question = ""
        messages.append(LibraryConversationEntry(role: .user, text: submitted))
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let answer = try await environment.processing.answerLibraryQuestion(
                    submitted,
                    recordings: recordings,
                    insightModel: settings.resolvedInsightModel
                )
                messages.append(LibraryConversationEntry(
                    role: .assistant,
                    text: answer.answer,
                    sources: answer.sources,
                    excerptCount: answer.excerptCount
                ))
            } catch {
                errorMessage = error.localizedDescription
                question = submitted
                focused = true
            }
        }
    }
}

private struct LibraryConversationEntry: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    var sources: [LibrarySourceCitation] = []
    var excerptCount: Int = 0
}

private struct LibraryConversationRow: View {
    let message: LibraryConversationEntry
    let onOpenSource: (LibrarySourceCitation) -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 100) }
            VStack(alignment: .leading, spacing: 9) {
                Text(message.text).textSelection(.enabled)
                if !message.sources.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(message.sources) { source in
                            Button {
                                onOpenSource(source)
                            } label: {
                                Label("\(source.recordingTitle) · \(source.startSeconds.clockString)", systemImage: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
                if message.excerptCount > 0 {
                    Text("Answer generated from \(message.excerptCount) locally selected excerpt\(message.excerptCount == 1 ? "" : "s").")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .contentSurface(tint: message.role == .user ? .accentColor : nil)
            .frame(maxWidth: 700, alignment: .leading)
            if message.role == .assistant { Spacer(minLength: 100) }
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) { content }
    }
}
