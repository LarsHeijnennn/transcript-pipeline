import SwiftData
import SwiftUI

private enum RecordingTab: String, CaseIterable, Identifiable {
    case notes
    case transcript
    case ask

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .transcript: "text.bubble"
        case .ask: "bubble.left.and.bubble.right"
        }
    }
}

struct RecordingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var environment: AppEnvironment
    @Query(sort: \CustomTemplateRecord.createdAt) private var customTemplates: [CustomTemplateRecord]

    @Bindable var recording: RecordingRecord
    @State private var player: AudioPlayerController
    @SceneStorage("recordingDetailSelectedTab") private var selectedTabRaw = RecordingTab.notes.rawValue
    @State private var selectedTemplateID: String
    @State private var actionError: String?
    @State private var exportError: String?

    init(recording: RecordingRecord) {
        self.recording = recording
        _player = State(initialValue: AudioPlayerController(url: recording.audioURL, duration: recording.durationSeconds))
        _selectedTemplateID = State(initialValue: recording.selectedTemplateID)
    }

    private var templates: [AnalysisTemplateDefinition] {
        AnalysisTemplateDefinition.builtIns + customTemplates.map(\.definition)
    }

    private var selectedTemplate: AnalysisTemplateDefinition {
        templates.first { $0.id == selectedTemplateID } ?? AnalysisTemplateDefinition.builtIns[0]
    }

    private var isProcessing: Bool {
        environment.processing.activeRecordingIDs.contains(recording.id)
    }

    private var selectedTab: RecordingTab {
        RecordingTab(rawValue: selectedTabRaw) ?? .notes
    }

    private var selectedTabBinding: Binding<RecordingTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            AppCanvas()
            VStack(spacing: 0) {
                header
                Group {
                    switch selectedTab {
                    case .notes:
                        NotesView(
                            recording: recording,
                            isProcessing: isProcessing,
                            onGenerate: { Task { await processOrRegenerate() } },
                            onSeek: seekToCitation
                        )
                    case .transcript:
                        TranscriptView(
                            recording: recording,
                            player: player,
                            isProcessing: isProcessing,
                            onProcess: { Task { await processOrRegenerate() } }
                        )
                    case .ask:
                        RecordingChatView(
                            recording: recording,
                            player: player,
                            isProcessing: isProcessing,
                            onProcess: { Task { await processOrRegenerate() } }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                AudioPlayerBar(player: player)
            }
        }
        .navigationTitle(recording.title)
        .alert("Couldn’t Complete the Action", isPresented: Binding(
            get: { actionError != nil || exportError != nil },
            set: { if !$0 { actionError = nil; exportError = nil } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(actionError ?? exportError ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Recording title", text: $recording.title)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { recording.updatedAt = Date(); try? modelContext.save() }
                    Text("\(recording.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationSeconds.clockString) · \(recording.sourceFormat.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    title: recording.processingStage.title,
                    symbol: recording.processingStage.symbolName,
                    color: stageColor
                )
            }
            if recording.processingStage.isActive || isProcessing {
                VStack(spacing: 6) {
                    HStack {
                        Text(recording.processingStage.title)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(recording.processingProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: recording.processingProgress)
                        .progressViewStyle(.linear)
                }
            }
            if let error = recording.lastError, recording.processingStage == .failed {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Processing stopped").font(.callout.weight(.semibold))
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Retry") { Task { await processOrRegenerate() } }
                        .liquidGlassButton()
                        .disabled(isProcessing)
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Label("Template", systemImage: "wand.and.sparkles")
                        .font(.callout.weight(.medium))
                    analysisTemplatePicker
                    Spacer()
                    recordingActions
                }
                HStack(spacing: 8) {
                    analysisTemplatePicker
                    Spacer(minLength: 4)
                    recordingActions
                }
            }
            Picker("View", selection: selectedTabBinding) {
                ForEach(RecordingTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 430)
            .glassControlPlate(
                cornerRadius: 14,
                horizontalPadding: 5,
                verticalPadding: 4
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .functionalGlass(cornerRadius: 20)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var analysisTemplatePicker: some View {
        Picker("Notes template", selection: $selectedTemplateID) {
            ForEach(templates) { template in
                Label(template.name, systemImage: template.systemImage).tag(template.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 190)
        .glassControlPlate(
            cornerRadius: 11,
            horizontalPadding: 5,
            verticalPadding: 3
        )
        .help("Choose how generated notes are organized")
    }

    private var recordingActions: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await processOrRegenerate() }
                } label: {
                    Label(processButtonTitle, systemImage: recording.segments.isEmpty ? "sparkles" : "arrow.clockwise")
                }
                .liquidGlassButton(prominent: recording.segments.isEmpty)
                .disabled(isProcessing)
                .help(processButtonTitle)
                .fixedSize()

                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { export(format) }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .liquidGlassButton()
                .disabled(recording.segments.isEmpty)
                .help("Export or share this recording")
                .fixedSize()
            }
        }
    }

    private var stageColor: Color {
        switch recording.processingStage {
        case .complete: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var processButtonTitle: String {
        if isProcessing { return recording.processingStage.title }
        if recording.segments.isEmpty { return recording.processingStage == .failed ? "Retry" : "Process" }
        return "Regenerate"
    }

    private func processOrRegenerate() async {
        recording.selectedTemplateID = selectedTemplateID
        do {
            if recording.segments.isEmpty {
                await environment.processing.process(
                    recording: recording,
                    template: selectedTemplate,
                    insightModel: settings.resolvedInsightModel,
                    modelContext: modelContext
                )
                if recording.processingStage == .failed { actionError = recording.lastError }
            } else {
                try await environment.processing.regenerateAnalysis(
                    recording: recording,
                    template: selectedTemplate,
                    insightModel: settings.resolvedInsightModel,
                    modelContext: modelContext
                )
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func export(_ format: ExportFormat) {
        do {
            let url = try ExportService.export(recording: recording, format: format)
            NativeSharing.share(url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func seekToCitation(_ citation: EvidenceCitation) {
        player.seek(to: citation.startSeconds)
        selectedTabRaw = RecordingTab.transcript.rawValue
    }
}

private struct AudioPlayerBar: View {
    @ObservedObject var player: AudioPlayerController

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .liquidGlassButton(prominent: true)
                .keyboardShortcut(.space, modifiers: [])
                Text(player.currentTime.clockString)
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
                Slider(
                    value: Binding(get: { player.currentTime }, set: player.seek),
                    in: 0...max(1, player.duration)
                )
                .glassControlPlate(
                    cornerRadius: 11,
                    horizontalPadding: 9,
                    verticalPadding: 3
                )
                Text(player.duration.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .functionalGlass(cornerRadius: AppStyle.floatingRadius)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }
}
