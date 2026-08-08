import SwiftData
import SwiftUI

struct NotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var recording: RecordingRecord
    let isProcessing: Bool
    let onGenerate: () -> Void
    let onSeek: (EvidenceCitation) -> Void
    @State private var selectedRevisionID: UUID?
    @State private var draftRevisionID: UUID?
    @State private var draftDocument: AnalysisDocument?
    @State private var pendingSave: Task<Void, Never>?

    private var selectedRevision: AnalysisRevisionRecord? {
        if let selectedRevisionID,
           let revision = recording.analyses.first(where: { $0.id == selectedRevisionID }) {
            return revision
        }
        return recording.currentAnalysis
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let revision = selectedRevision, let document = document(for: revision) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Notes title", text: documentTextBinding(\.title, revision: revision))
                                .font(.largeTitle.weight(.semibold))
                                .textFieldStyle(.plain)
                            Text(revision.isStale ? "Based on an earlier transcript version" : "Working notes")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recording.analyses.count > 1 {
                            Picker("Revision", selection: revisionBinding) {
                                ForEach(recording.sortedAnalyses) { option in
                                    Text(option.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .tag(Optional(option.id))
                                }
                            }
                            .frame(maxWidth: 210)
                            .help("Open an earlier generated revision")
                        }
                    }
                    if revision.isStale {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("These notes are out of date").font(.callout.weight(.semibold))
                                Text("The transcript or speaker assignments changed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Regenerate Notes", action: onGenerate)
                                .liquidGlassButton()
                                .disabled(isProcessing)
                        }
                        .padding(14)
                        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(alignment: .top, spacing: 14) {
                        SymbolBadge(symbol: "sparkles", size: 42)
                        TextEditor(text: documentTextBinding(\.overview, revision: revision))
                            .font(.title3)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 70)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .contentSurface(tint: .accentColor)

                    ForEach(Array(document.sections.enumerated()), id: \.element.id) { index, _ in
                        EditableNoteSection(
                            heading: sectionHeadingBinding(index: index, revision: revision),
                            items: sectionItemsBinding(index: index, revision: revision),
                            onSeek: onSeek
                        )
                    }
                    EditableNoteSection(
                        fixedHeading: "Decisions",
                        items: citedItemsBinding(\.decisions, revision: revision),
                        onSeek: onSeek
                    )

                    EditableActionItems(
                        items: actionItemsBinding(revision: revision),
                        onSeek: onSeek
                    )
                    EditableNoteSection(
                        fixedHeading: "Open questions",
                        items: citedItemsBinding(\.openQuestions, revision: revision),
                        onSeek: onSeek
                    )
                } else {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "note.text.badge.plus")
                    } description: {
                        Text(recording.segments.isEmpty ? "Process the recording to create a transcript and notes." : "Generate notes from the transcript using the selected template.")
                    } actions: {
                        Button(recording.segments.isEmpty ? "Process Recording" : "Generate Notes", action: onGenerate)
                            .liquidGlassButton(prominent: true)
                            .disabled(isProcessing)
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                }

                if !recording.usageEntries.isEmpty {
                    UsageSummary(entries: recording.usageEntries)
                }
            }
            .frame(maxWidth: AppStyle.pageWidth, alignment: .leading)
            .padding(30)
        }
        .onAppear {
            selectedRevisionID = recording.currentAnalysis?.id
            loadDraft(for: selectedRevision)
        }
        .onChange(of: recording.currentAnalysis?.id) { _, id in
            if selectedRevisionID == nil || !recording.analyses.contains(where: { $0.id == selectedRevisionID }) {
                selectedRevisionID = id
                loadDraft(for: selectedRevision)
            }
        }
        .onDisappear { commitDraft() }
    }

    private var revisionBinding: Binding<UUID?> {
        Binding(get: { selectedRevision?.id }, set: { switchRevision(to: $0) })
    }

    private func mutate(_ revision: AnalysisRevisionRecord, _ change: (inout AnalysisDocument) -> Void) {
        guard var document = document(for: revision) else { return }
        change(&document)
        draftRevisionID = revision.id
        draftDocument = document
        scheduleSave()
    }

    private func document(for revision: AnalysisRevisionRecord) -> AnalysisDocument? {
        if draftRevisionID == revision.id, let draftDocument { return draftDocument }
        return revision.document
    }

    private func loadDraft(for revision: AnalysisRevisionRecord?) {
        pendingSave?.cancel()
        draftRevisionID = revision?.id
        draftDocument = revision?.document
    }

    private func switchRevision(to id: UUID?) {
        commitDraft()
        selectedRevisionID = id
        loadDraft(for: selectedRevision)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            commitDraft()
        }
    }

    private func commitDraft() {
        pendingSave?.cancel()
        guard let draftRevisionID,
              let draftDocument,
              let revision = recording.analyses.first(where: { $0.id == draftRevisionID }),
              revision.document != draftDocument else { return }
        revision.document = draftDocument
        recording.updatedAt = Date()
        try? modelContext.save()
    }

    private func documentTextBinding(
        _ keyPath: WritableKeyPath<AnalysisDocument, String>,
        revision: AnalysisRevisionRecord
    ) -> Binding<String> {
        Binding(
            get: { document(for: revision)?[keyPath: keyPath] ?? "" },
            set: { value in mutate(revision) { $0[keyPath: keyPath] = value } }
        )
    }

    private func sectionHeadingBinding(index: Int, revision: AnalysisRevisionRecord) -> Binding<String> {
        Binding(
            get: { document(for: revision)?.sections[safe: index]?.heading ?? "Section" },
            set: { value in mutate(revision) { document in
                guard document.sections.indices.contains(index) else { return }
                document.sections[index].heading = value
            } }
        )
    }

    private func sectionItemsBinding(index: Int, revision: AnalysisRevisionRecord) -> Binding<[CitedText]> {
        Binding(
            get: { document(for: revision)?.sections[safe: index]?.items ?? [] },
            set: { value in mutate(revision) { document in
                guard document.sections.indices.contains(index) else { return }
                document.sections[index].items = value
            } }
        )
    }

    private func citedItemsBinding(
        _ keyPath: WritableKeyPath<AnalysisDocument, [CitedText]>,
        revision: AnalysisRevisionRecord
    ) -> Binding<[CitedText]> {
        Binding(
            get: { document(for: revision)?[keyPath: keyPath] ?? [] },
            set: { value in mutate(revision) { $0[keyPath: keyPath] = value } }
        )
    }

    private func actionItemsBinding(revision: AnalysisRevisionRecord) -> Binding<[ActionItem]> {
        Binding(
            get: { document(for: revision)?.actionItems ?? [] },
            set: { value in mutate(revision) { $0.actionItems = value } }
        )
    }
}

private struct UsageSummary: View {
    let entries: [UsageEntry]

    private var totalCost: Decimal {
        entries.compactMap(\.estimatedCostUSD).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModernSectionTitle(title: "API usage", subtitle: "Per-operation estimate", symbol: "gauge.with.dots.needle.67percent")
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.operation).fontWeight(.medium)
                        Text(entry.model).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(entry.usage.totalTokens.formatted()) tokens")
                    Text(cost(entry.estimatedCostUSD))
                        .frame(width: 84, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text("Estimated total").fontWeight(.semibold)
                Spacer()
                Text(cost(totalCost)).fontWeight(.semibold)
            }
            Text("USD estimate using rates updated \(AppConfiguration.pricingUpdatedAt). Provider-reported token usage is retained with each operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .contentSurface()
    }

    private func cost(_ value: Decimal?) -> String {
        guard let value else { return "Unknown" }
        return NSDecimalNumber(decimal: value).doubleValue.formatted(
            .currency(code: "USD").precision(.fractionLength(4))
        )
    }
}

private struct EditableNoteSection: View {
    var fixedHeading: String?
    var heading: Binding<String>?
    @Binding var items: [CitedText]
    let onSeek: (EvidenceCitation) -> Void

    init(
        fixedHeading: String? = nil,
        heading: Binding<String>? = nil,
        items: Binding<[CitedText]>,
        onSeek: @escaping (EvidenceCitation) -> Void
    ) {
        self.fixedHeading = fixedHeading
        self.heading = heading
        _items = items
        self.onSeek = onSeek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let heading {
                    TextField("Section heading", text: heading)
                        .font(.headline)
                        .textFieldStyle(.plain)
                } else {
                    ModernSectionTitle(title: fixedHeading ?? "Notes", symbol: sectionSymbol)
                }
                Spacer()
                Button("Add item", systemImage: "plus") {
                    items.append(CitedText(text: ""))
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            if items.isEmpty {
                Text("Nothing confirmed in the transcript.").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    Text("•")
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Note", text: itemTextBinding(index), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                        CitationButtons(citations: item.citations, onSeek: onSeek)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        items.remove(at: index)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                }
            }
        }
        .padding(18)
        .contentSurface()
    }

    private var sectionSymbol: String {
        switch (fixedHeading ?? heading?.wrappedValue ?? "").lowercased() {
        case "decisions": "checkmark.seal"
        case "open questions": "questionmark.bubble"
        default: "text.alignleft"
        }
    }

    private func itemTextBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index].text : "" },
            set: { if items.indices.contains(index) { items[index].text = $0 } }
        )
    }
}

private struct EditableActionItems: View {
    @Binding var items: [ActionItem]
    let onSeek: (EvidenceCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ModernSectionTitle(title: "Action items", symbol: "checklist")
                Spacer()
                Button("Add action item", systemImage: "plus") {
                    items.append(ActionItem(task: ""))
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
            if items.isEmpty {
                Text("No confirmed action items found.").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("Completed", isOn: binding(index, \.isCompleted))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Action item", text: binding(index, \.task), axis: .vertical)
                            .textFieldStyle(.plain)
                            .strikethrough(item.isCompleted)
                        HStack {
                            TextField("Owner", text: binding(index, \.owner))
                            TextField("Due date", text: binding(index, \.dueDate))
                            CitationButtons(citations: item.citations, onSeek: onSeek)
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        items.remove(at: index)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                }
                .padding(12)
                .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18)
        .contentSurface()
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<ActionItem, Value>) -> Binding<Value> {
        Binding(
            get: { items[index][keyPath: keyPath] },
            set: { if items.indices.contains(index) { items[index][keyPath: keyPath] = $0 } }
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct CitationButtons: View {
    let citations: [EvidenceCitation]
    let onSeek: (EvidenceCitation) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(citations.prefix(4)) { citation in
                Button(citation.startSeconds.clockString) { onSeek(citation) }
                    .buttonStyle(.borderless)
                    .font(.caption.monospacedDigit())
                    .help("Play cited transcript segment")
            }
        }
    }
}
