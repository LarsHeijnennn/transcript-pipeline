import SwiftUI

struct NotesView: View {
    let recording: RecordingRecord
    let isProcessing: Bool
    let onGenerate: () -> Void
    let onSeek: (EvidenceCitation) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let revision = recording.currentAnalysis, let document = revision.document {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).font(.largeTitle.weight(.semibold))
                            Text("Generated notes")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recording.analyses.count > 1 {
                            StatusPill(
                                title: "Revision \(recording.analyses.count)",
                                symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                color: .secondary
                            )
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
                        Text(document.overview)
                            .font(.title3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .contentSurface(tint: .accentColor)

                    ForEach(document.sections) { section in
                        NoteSection(title: section.heading, items: section.items, onSeek: onSeek)
                    }
                    NoteSection(title: "Decisions", items: document.decisions, onSeek: onSeek)

                    VStack(alignment: .leading, spacing: 12) {
                        ModernSectionTitle(title: "Action items", symbol: "checklist")
                        if document.actionItems.isEmpty {
                            Text("No confirmed action items found.").foregroundStyle(.secondary)
                        }
                        ForEach(document.actionItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.task).textSelection(.enabled)
                                    HStack {
                                        if !item.owner.isEmpty { Label(item.owner, systemImage: "person") }
                                        if !item.dueDate.isEmpty { Label(item.dueDate, systemImage: "calendar") }
                                        CitationButtons(citations: item.citations, onSeek: onSeek)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(18)
                    .contentSurface()
                    NoteSection(title: "Open questions", items: document.openQuestions, onSeek: onSeek)
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

private struct NoteSection: View {
    let title: String
    let items: [CitedText]
    let onSeek: (EvidenceCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModernSectionTitle(title: title, symbol: sectionSymbol)
            if items.isEmpty {
                Text("Nothing confirmed in the transcript.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 9) {
                    Text("•")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.text).textSelection(.enabled)
                        CitationButtons(citations: item.citations, onSeek: onSeek)
                    }
                }
            }
        }
        .padding(18)
        .contentSurface()
    }

    private var sectionSymbol: String {
        switch title.lowercased() {
        case "decisions": "checkmark.seal"
        case "open questions": "questionmark.bubble"
        default: "text.alignleft"
        }
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
