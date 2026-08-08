import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum NavigationSelection: Hashable {
    case library
    case settings
    case recording(UUID)
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var environment: AppEnvironment
    @Query(sort: \RecordingRecord.importedAt, order: .reverse) private var recordings: [RecordingRecord]

    @SceneStorage("rootNavigationSelection") private var storedNavigationSelection = ""
    @State private var navigationSelection: NavigationSelection? = .library
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var showingRecorder = false
    @State private var pendingImport: PendingImport?
    @State private var importError: String?
    @State private var importStatus: String?
    @State private var recordingToDelete: RecordingRecord?

    private var selectedRecording: RecordingRecord? {
        guard case .recording(let id) = navigationSelection else { return nil }
        return recordings.first { $0.id == id }
    }

    private var filteredRecordings: [RecordingRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.sourceFormat.localizedCaseInsensitiveContains(trimmed)
                || $0.importedAt.formatted(date: .numeric, time: .omitted).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ZStack {
            AppCanvas()
            NavigationSplitView {
                List(selection: $navigationSelection) {
                    Section {
                        Label("Library", systemImage: "waveform")
                            .symbolVariant(navigationSelection == .library ? .fill : .none)
                            .tag(NavigationSelection.library)
                        Label("Settings", systemImage: "gearshape")
                            .symbolVariant(navigationSelection == .settings ? .fill : .none)
                            .tag(NavigationSelection.settings)
                    }

                    Section("Recordings") {
                        ForEach(filteredRecordings) { recording in
                            RecordingRow(recording: recording)
                                .tag(NavigationSelection.recording(recording.id))
                                .contextMenu {
                                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                        recordingToDelete = recording
                                    }
                                }
                        }
                        if recordings.isEmpty {
                            Text("No recordings yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if filteredRecordings.isEmpty {
                            Label("No matches", systemImage: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .navigationTitle(AppConfiguration.displayName)
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search recordings")
            } detail: {
                if navigationSelection == .settings {
                    SettingsView()
                } else if let selectedRecording {
                    RecordingDetailView(recording: selectedRecording)
                        .id(selectedRecording.id)
                } else {
                    LibraryWelcomeView(
                        recordingCount: recordings.count,
                        isSearching: !searchText.trimmed.isEmpty,
                        onRecord: { showingRecorder = true },
                        onImport: { showingImporter = true }
                    )
                }
            }
            .background(.clear)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingRecorder = true
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Record a conversation (⇧⌘R)")
                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Import an audio file (⌘O)")
            }
        }
        .overlay(alignment: .top) {
            if let importStatus {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(importStatus).font(.callout.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .functionalGlass(cornerRadius: 18)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showingRecorder) {
            LiveRecordingView(recorder: environment.liveRecording) { result, title, language, authorized in
                Task {
                    await importLiveRecording(
                        result,
                        title: title,
                        language: language,
                        authorized: authorized
                    )
                }
            }
            .environmentObject(settings)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): pendingImport = urls.first.map(PendingImport.init(url:))
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .sheet(item: $pendingImport) { request in
            ImportConfirmationView(url: request.url) { title, language, authorized in
                Task { await importRecording(url: request.url, title: title, language: language, authorized: authorized) }
            }
        }
        .alert("Couldn’t Complete the Action", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown import error")
        }
        .confirmationDialog(
            "Move this managed recording to Trash?",
            isPresented: Binding(
                get: { recordingToDelete != nil },
                set: { if !$0 { recordingToDelete = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let recordingToDelete { delete(recordingToDelete) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported source file stays untouched. Only this app’s managed copy and local notes are removed.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            pendingImport = PendingImport(url: url)
            return true
        }
        .task { restoreNavigationSelection() }
        .onChange(of: navigationSelection) { _, selection in
            store(selection)
        }
        .onChange(of: recordings.map(\.id)) { _, ids in
            if case .recording(let id) = navigationSelection, !ids.contains(id) {
                navigationSelection = ids.first.map(NavigationSelection.recording) ?? .library
            }
        }
    }

    private var supportedTypes: [UTType] {
        let extensionTypes = AppConfiguration.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        return Array(Set(extensionTypes + [.audio, .movie, .data]))
    }

    private func importRecording(url: URL, title: String, language: LanguageHint, authorized: Bool) async {
        let id = UUID()
        withAnimation { importStatus = "Adding recording to your library…" }
        defer { withAnimation { importStatus = nil } }
        do {
            let imported = try await environment.library.importFile(from: url, recordingID: id)
            let recording = RecordingRecord(
                id: id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? imported.suggestedTitle : title,
                durationSeconds: imported.durationSeconds,
                localAudioPath: imported.managedURL.path,
                sourceFormat: imported.sourceFormat,
                languageHint: language,
                authorizationConfirmed: authorized
            )
            recording.insightModel = settings.resolvedInsightModel
            modelContext.insert(recording)
            try modelContext.save()
            navigationSelection = .recording(recording.id)
        } catch {
            try? environment.library.moveRecordingToTrash(recordingID: id)
            importError = error.localizedDescription
        }
    }

    private func importLiveRecording(
        _ result: LiveRecordingResult,
        title: String,
        language: LanguageHint,
        authorized: Bool
    ) async {
        let id = UUID()
        withAnimation { importStatus = "Saving recording to your library…" }
        defer { withAnimation { importStatus = nil } }
        do {
            let imported = try await environment.library.importFile(from: result.fileURL, recordingID: id)
            let recording = RecordingRecord(
                id: id,
                title: title.isEmpty ? imported.suggestedTitle : title,
                durationSeconds: imported.durationSeconds,
                localAudioPath: imported.managedURL.path,
                sourceFormat: imported.sourceFormat,
                languageHint: language,
                authorizationConfirmed: authorized
            )
            recording.insightModel = settings.resolvedInsightModel
            modelContext.insert(recording)
            try modelContext.save()
            try environment.liveRecording.discard(result)
            navigationSelection = .recording(recording.id)
        } catch {
            try? environment.library.moveRecordingToTrash(recordingID: id)
            importError = "The recording was saved locally, but could not be added to the library: \(error.localizedDescription)"
        }
    }

    private func delete(_ recording: RecordingRecord) {
        do {
            try environment.library.moveRecordingToTrash(recordingID: recording.id)
            if selectedRecording?.id == recording.id { navigationSelection = .library }
            modelContext.delete(recording)
            try modelContext.save()
        } catch {
            importError = error.localizedDescription
        }
        recordingToDelete = nil
    }

    private func restoreNavigationSelection() {
        if storedNavigationSelection == "settings" {
            navigationSelection = .settings
        } else if storedNavigationSelection == "library" {
            navigationSelection = .library
        } else if storedNavigationSelection.hasPrefix("recording:"),
                  let id = UUID(uuidString: String(storedNavigationSelection.dropFirst("recording:".count))),
                  recordings.contains(where: { $0.id == id }) {
            navigationSelection = .recording(id)
        } else if let first = recordings.first {
            navigationSelection = .recording(first.id)
        } else {
            navigationSelection = .library
        }
    }

    private func store(_ selection: NavigationSelection?) {
        switch selection {
        case .library: storedNavigationSelection = "library"
        case .settings: storedNavigationSelection = "settings"
        case .recording(let id): storedNavigationSelection = "recording:\(id.uuidString)"
        case nil: break
        }
    }
}

private struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct RecordingRow: View {
    let recording: RecordingRecord

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: recording.processingStage.symbolName, color: stageColor, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(recording.importedAt, style: .date)
                    Text("•")
                    Text(recording.durationSeconds.clockString)
                    if recording.processingStage != .complete && recording.processingStage != .imported {
                        Text("•")
                        Text(recording.processingStage.title)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var stageColor: Color {
        switch recording.processingStage {
        case .complete: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

private struct ImportConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onConfirm: (String, LanguageHint, Bool) -> Void

    @State private var title: String
    @State private var language: LanguageHint = .automatic
    @State private var authorized = false

    init(url: URL, onConfirm: @escaping (String, LanguageHint, Bool) -> Void) {
        self.url = url
        self.onConfirm = onConfirm
        _title = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: "waveform.badge.plus", size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import recording").font(.title2.weight(.semibold))
                    Text("Create a local managed copy").font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                LabeledContent("File", value: url.lastPathComponent)
                TextField("Title", text: $title)
                Picker("Language", selection: $language) {
                    ForEach(LanguageHint.allCases) { hint in Text(hint.title).tag(hint) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("What leaves this Mac", systemImage: "lock.shield")
                    .font(.headline)
                Text("Importing now only creates a local managed copy. When you later choose Process, audio is sent to OpenAI Transcriptions; the resulting transcript and your questions are sent to OpenAI Responses. The managed original and local library stay on this Mac.")
                    .foregroundStyle(.secondary)
                Toggle("I am permitted to process this recording and have informed participants where required.", isOn: $authorized)
            }
            .padding(16)
            .contentSurface(tint: .accentColor)
            HStack {
                Spacer()
                LiquidGlassGroup {
                    HStack(spacing: AppStyle.controlSpacing) {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .liquidGlassButton()
                        Button("Import") {
                            onConfirm(title, language, authorized)
                            dismiss()
                        }
                        .liquidGlassButton(prominent: true)
                        .disabled(!authorized)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct LibraryWelcomeView: View {
    let recordingCount: Int
    let isSearching: Bool
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            SymbolBadge(symbol: "waveform.and.mic", color: .accentColor, size: 74)
            VStack(spacing: 7) {
                Text(isSearching ? "No matching recordings" : recordingCount == 0 ? "Your conversations, made useful" : "Your library")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(welcomeDescription)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            LiquidGlassGroup(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Record", systemImage: "record.circle", action: onRecord)
                        .liquidGlassButton(prominent: true)
                        .tint(.red)
                        .controlSize(.large)
                    Button("Import Audio", systemImage: "square.and.arrow.down", action: onImport)
                        .liquidGlassButton()
                        .controlSize(.large)
                }
            }
        }
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeDescription: String {
        if isSearching { return "Try another title, date, or file type." }
        if recordingCount > 0 { return "Select a recording in the sidebar, or add a new conversation." }
        return "Record a meeting or import audio, then turn it into a searchable transcript, decisions, and action items."
    }
}
