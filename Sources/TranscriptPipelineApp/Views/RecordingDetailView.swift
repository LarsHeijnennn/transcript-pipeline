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
    let searchTarget: SearchNavigationTarget?
    @State private var player: AudioPlayerController
    @SceneStorage("recordingDetailSelectedTab") private var selectedTabRaw = RecordingTab.notes.rawValue
    @State private var selectedTemplateID: String
    @State private var actionError: String?
    @State private var exportError: String?
    @State private var newTag = ""

    init(recording: RecordingRecord, searchTarget: SearchNavigationTarget? = nil) {
        self.recording = recording
        self.searchTarget = searchTarget
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
            || environment.processing.queuedRecordingIDs.contains(recording.id)
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
        .task { applySearchTarget(searchTarget) }
        .onChange(of: searchTarget?.id) { _, _ in applySearchTarget(searchTarget) }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Recording title", text: $recording.title)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { recording.updatedAt = Date(); try? modelContext.save() }
                    HStack(spacing: 7) {
                        Text("\(recording.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(recording.durationSeconds.clockString) · \(recording.sourceFormat.uppercased())")
                        if !recording.folderName.isEmpty {
                            Label(recording.folderName, systemImage: "folder")
                        }
                        ForEach(recording.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    TextField("Folder", text: $recording.folderName)
                        .onSubmit {
                            recording.updatedAt = Date()
                            try? modelContext.save()
                        }
                    Divider()
                    TextField("New tag", text: $newTag)
                        .onSubmit(addTag)
                    if !recording.tags.isEmpty {
                        Divider()
                        ForEach(recording.tags, id: \.self) { tag in
                            Button("Remove #\(tag)", systemImage: "xmark") { removeTag(tag) }
                        }
                    }
                } label: {
                    Label("Organize", systemImage: "folder.badge.gearshape")
                }
                .liquidGlassButton()
                .help("Set folder and tags")
                Button {
                    recording.isFavorite.toggle()
                    recording.updatedAt = Date()
                    try? modelContext.save()
                } label: {
                    Image(systemName: recording.isFavorite ? "star.fill" : "star")
                }
                .liquidGlassButton()
                .help(recording.isFavorite ? "Remove from favorites" : "Add to favorites")
                StatusPill(
                    title: recording.processingStage.title,
                    symbol: recording.processingStage.symbolName,
                    color: stageColor
                )
            }
            if recording.processingStage.isActive || isProcessing {
                VStack(spacing: 6) {
                    HStack {
                        Text(processingStatusText)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(recording.processingProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: recording.processingProgress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(recording.processingDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            environment.processing.cancel(recordingID: recording.id)
                        }
                        .buttonStyle(.borderless)
                    }
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
                    Section("Copy") {
                        Button("Copy notes", systemImage: "doc.on.doc") {
                            NativeSharing.copy(ExportService.notesOnly(for: recording))
                        }
                        Button("Copy action items", systemImage: "checklist") {
                            NativeSharing.copy(ExportService.actionItemsOnly(for: recording))
                        }
                    }
                    Section("Export") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { export(format) }
                    }
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

    private var processingStatusText: String {
        if let position = environment.processing.queuePosition(for: recording.id) {
            return "Queued · position \(position)"
        }
        return recording.processingStage.title
    }

    private func processOrRegenerate() async {
        recording.selectedTemplateID = selectedTemplateID
        do {
            if recording.segments.isEmpty {
                environment.processing.enqueue(
                    recording: recording,
                    template: selectedTemplate,
                    insightModel: settings.resolvedInsightModel,
                    modelContext: modelContext,
                    notifyWhenComplete: settings.notifyWhenProcessingCompletes
                )
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

    private func applySearchTarget(_ target: SearchNavigationTarget?) {
        guard let target, target.recordingID == recording.id, let timestamp = target.timestamp else { return }
        player.seek(to: timestamp)
        selectedTabRaw = RecordingTab.transcript.rawValue
    }

    private func addTag() {
        let tag = newTag.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty else { return }
        recording.tags.append(tag)
        recording.updatedAt = Date()
        newTag = ""
        try? modelContext.save()
    }

    private func removeTag(_ tag: String) {
        recording.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        recording.updatedAt = Date()
        try? modelContext.save()
    }
}

private struct AudioPlayerBar: View {
    @ObservedObject var player: AudioPlayerController
    @State private var waveform: [Double] = []

    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 12) {
                Button { player.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .liquidGlassButton()
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Back 10 seconds (⌘←)")
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .liquidGlassButton(prominent: true)
                .keyboardShortcut(.space, modifiers: [])
                Button { player.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .liquidGlassButton()
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Forward 10 seconds (⌘→)")
                Text(player.currentTime.clockString)
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
                WaveformScrubber(
                    samples: waveform,
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    onSeekFraction: { player.seek(to: $0 * player.duration) }
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
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            player.setPlaybackRate(Float(rate))
                        } label: {
                            if abs(Double(player.playbackRate) - rate) < 0.01 {
                                Label("\(rate.formatted())×", systemImage: "checkmark")
                            } else {
                                Text("\(rate.formatted())×")
                            }
                        }
                    }
                } label: {
                    Text("\(Double(player.playbackRate).formatted())×")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34)
                }
                .liquidGlassButton()
                .help("Playback speed")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .functionalGlass(cornerRadius: AppStyle.floatingRadius)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .task(id: player.sourceURL) {
            let samples = await AudioWaveformService.samples(for: player.sourceURL)
            guard !Task.isCancelled else { return }
            waveform = samples
        }
    }
}

private struct WaveformScrubber: View {
    let samples: [Double]
    let progress: Double
    let onSeekFraction: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let values = samples.isEmpty ? Array(repeating: 0.28, count: 80) : samples
                let spacing: CGFloat = 1.5
                let barWidth = max(1, (size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count))
                for (index, sample) in values.enumerated() {
                    let height = max(3, size.height * CGFloat(0.12 + 0.88 * sample))
                    let x = CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                    let fraction = Double(index) / Double(max(1, values.count - 1))
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(fraction <= progress ? .accentColor : .secondary.opacity(0.35))
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeekFraction(min(max(0, value.location.x / max(1, geometry.size.width)), 1))
            })
        }
        .frame(minWidth: 150, minHeight: 30, maxHeight: 30)
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}
