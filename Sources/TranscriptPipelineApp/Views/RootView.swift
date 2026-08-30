import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum NavigationSelection: Hashable {
    case library
    case libraryAsk
    case settings
    case recording(UUID)
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var environment: AppEnvironment
    @Query(sort: \RecordingRecord.importedAt, order: .reverse) private var recordings: [RecordingRecord]
    @StateObject private var librarySearch = LibrarySearchController()

    @SceneStorage("rootNavigationSelection") private var storedNavigationSelection = ""
    @State private var navigationSelection: NavigationSelection? = .library
    @State private var searchText = ""
    @State private var smartFilter: LibrarySmartFilter = .all
    @State private var selectedFolder: String?
    @State private var selectedTag: String?
    @State private var searchTarget: SearchNavigationTarget?
    @State private var showingImporter = false
    @State private var showingRecorder = false
    @State private var pendingImport: PendingImport?
    @State private var queuedImportURLs: [URL] = []
    @State private var importError: String?
    @State private var importStatus: String?
    @State private var recordingToDelete: RecordingRecord?
    @State private var availableUpdate: AppUpdateInfo?

    private var selectedRecording: RecordingRecord? {
        guard case .recording(let id) = navigationSelection else { return nil }
        return recordings.first { $0.id == id }
    }

    private var filteredRecordings: [RecordingRecord] {
        guard librarySearch.isReady else { return recordings }
        return recordings.filter { librarySearch.result.recordingIDs.contains($0.id) }
    }

    private var searchMatches: [RecordingSearchMatch] {
        librarySearch.result.matches
    }

    private var folders: [String] {
        librarySearch.result.folders
    }

    private var tags: [String] {
        librarySearch.result.tags
    }

    private var librarySearchKey: LibrarySearchKey {
        LibrarySearchKey(
            query: searchText,
            filterRaw: smartFilter.rawValue,
            folder: selectedFolder,
            tag: selectedTag,
            revisions: recordings.map { recording in
                LibraryRecordingRevision(
                    id: recording.id,
                    updatedAt: recording.updatedAt,
                    title: recording.title,
                    folder: recording.folderName,
                    tagsData: recording.tagsData,
                    isFavorite: recording.isFavorite,
                    processingStageRaw: recording.processingStageRaw,
                    segmentCount: recording.segments.count,
                    speakerCount: recording.speakers.count,
                    analysisCount: recording.analyses.count
                )
            }
        )
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
                        Label("Ask Library", systemImage: "books.vertical")
                            .symbolVariant(navigationSelection == .libraryAsk ? .fill : .none)
                            .tag(NavigationSelection.libraryAsk)
                        Label("Settings", systemImage: "gearshape")
                            .symbolVariant(navigationSelection == .settings ? .fill : .none)
                            .tag(NavigationSelection.settings)
                    }

                    Section("Smart views") {
                        ForEach(LibrarySmartFilter.allCases) { filter in
                            Button {
                                smartFilter = filter
                                selectedFolder = nil
                                selectedTag = nil
                                navigationSelection = .library
                            } label: {
                                HStack {
                                    Label(filter.title, systemImage: filter.symbol)
                                    Spacer()
                                    Text(filterCount(filter).formatted())
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(smartFilter == filter && selectedFolder == nil && selectedTag == nil ? Color.accentColor : .primary)
                        }
                    }

                    if !folders.isEmpty {
                        Section("Folders") {
                            ForEach(folders, id: \.self) { folder in
                                Button {
                                    selectedFolder = folder
                                    selectedTag = nil
                                    smartFilter = .all
                                    navigationSelection = .library
                                } label: {
                                    Label(folder, systemImage: "folder")
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(selectedFolder == folder ? Color.accentColor : .primary)
                            }
                        }
                    }

                    if !tags.isEmpty {
                        Section("Tags") {
                            ForEach(tags, id: \.self) { tag in
                                Button {
                                    selectedTag = tag
                                    selectedFolder = nil
                                    smartFilter = .all
                                    navigationSelection = .library
                                } label: {
                                    Label(tag, systemImage: "tag")
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(selectedTag == tag ? Color.accentColor : .primary)
                            }
                        }
                    }

                    Section("Recordings") {
                        ForEach(filteredRecordings) { recording in
                            RecordingRow(recording: recording, match: bestMatch(for: recording))
                                .tag(NavigationSelection.recording(recording.id))
                                .simultaneousGesture(TapGesture().onEnded {
                                    if let match = bestMatch(for: recording), match.timestamp != nil {
                                        searchTarget = SearchNavigationTarget(recordingID: recording.id, timestamp: match.timestamp)
                                    }
                                })
                                .contextMenu {
                                    Button(recording.isFavorite ? "Remove Favorite" : "Favorite", systemImage: recording.isFavorite ? "star.slash" : "star") {
                                        recording.isFavorite.toggle()
                                        recording.updatedAt = Date()
                                        try? modelContext.save()
                                    }
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
                } else if navigationSelection == .libraryAsk {
                    LibraryAskView(recordings: recordings, onOpenSource: openLibrarySource)
                } else if let selectedRecording {
                    RecordingDetailView(recording: selectedRecording, searchTarget: searchTarget)
                        .id(selectedRecording.id)
                } else {
                    LibraryWelcomeView(
                        recordingCount: filteredRecordings.count,
                        isSearching: !searchText.trimmed.isEmpty,
                        contextTitle: libraryContextTitle,
                        matches: searchMatches,
                        recordings: recordings,
                        onSelectMatch: selectSearchMatch,
                        onProcessAll: processVisibleRecordings,
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
        .sheet(isPresented: Binding(
            get: { !settings.hasAcknowledgedPrivacy },
            set: { if !$0 { settings.hasAcknowledgedPrivacy = true } }
        )) {
            OnboardingView()
                .environmentObject(settings)
                .environmentObject(environment)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): beginImportQueue(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .sheet(item: $pendingImport, onDismiss: advanceImportQueue) { request in
            if request.url.pathExtension.lowercased() == AppConfiguration.archiveExtension {
                PackageImportConfirmationView(url: request.url) {
                    Task { await restorePackage(url: request.url) }
                }
            } else {
                ImportConfirmationView(url: request.url) { title, language, authorized in
                    Task { await importRecording(url: request.url, title: title, language: language, authorized: authorized) }
                }
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
        .alert("What Was Said \(availableUpdate?.version ?? "") is available", isPresented: Binding(
            get: { availableUpdate != nil },
            set: { if !$0 { availableUpdate = nil } }
        )) {
            Button("Open Release") {
                if let url = availableUpdate?.downloadURL ?? availableUpdate?.releaseURL {
                    NSWorkspace.shared.open(url)
                }
                availableUpdate = nil
            }
            Button("Later", role: .cancel) { availableUpdate = nil }
        } message: {
            Text("Download the signed release, replace the app in Applications, and reopen it. Your local library remains in Application Support.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            pendingImport = PendingImport(url: url)
            return true
        }
        .task {
            LibraryDiagnosticsService.recoverInterruptedJobs(recordings: recordings)
            try? modelContext.save()
            restoreNavigationSelection()
            if settings.automaticallyCheckForUpdates {
                availableUpdate = try? await UpdateService().checkForUpdate()
            }
        }
        .task(id: librarySearchKey) {
            await librarySearch.refresh(
                recordings: recordings,
                query: searchText,
                filter: smartFilter,
                folder: selectedFolder,
                tag: selectedTag
            )
        }
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
        let archive = UTType(exportedAs: "nl.larsheijnen.transcriptpipeline.archive", conformingTo: .package)
        return Array(Set(extensionTypes + [.audio, .movie, archive]))
    }

    private var libraryContextTitle: String {
        if let selectedFolder { return selectedFolder }
        if let selectedTag { return "#\(selectedTag)" }
        return smartFilter.title
    }

    private func filterCount(_ filter: LibrarySmartFilter) -> Int {
        librarySearch.result.filterCounts[filter] ?? (filter == .all ? recordings.count : 0)
    }

    private func bestMatch(for recording: RecordingRecord) -> RecordingSearchMatch? {
        librarySearch.result.bestMatchByRecordingID[recording.id]
    }

    private func selectSearchMatch(_ match: RecordingSearchMatch) {
        navigationSelection = .recording(match.recordingID)
        searchTarget = SearchNavigationTarget(recordingID: match.recordingID, timestamp: match.timestamp)
    }

    private func openLibrarySource(_ source: LibrarySourceCitation) {
        navigationSelection = .recording(source.recordingID)
        searchTarget = SearchNavigationTarget(recordingID: source.recordingID, timestamp: source.startSeconds)
    }

    private func beginImportQueue(_ urls: [URL]) {
        guard let first = urls.first else { return }
        pendingImport = PendingImport(url: first)
        queuedImportURLs = Array(urls.dropFirst())
    }

    private func advanceImportQueue() {
        guard let next = queuedImportURLs.first else { return }
        queuedImportURLs.removeFirst()
        pendingImport = PendingImport(url: next)
    }

    private func restorePackage(url: URL) async {
        withAnimation { importStatus = "Restoring recording package…" }
        defer { withAnimation { importStatus = nil } }
        do {
            let recording = try await PortableLibraryService.importPackage(
                from: url,
                library: environment.library,
                modelContext: modelContext
            )
            navigationSelection = .recording(recording.id)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func processVisibleRecordings() {
        for recording in filteredRecordings where recording.segments.isEmpty && !recording.processingStage.isActive {
            environment.processing.enqueue(
                recording: recording,
                template: AnalysisTemplateDefinition.builtIns[0],
                insightModel: settings.resolvedInsightModel,
                modelContext: modelContext,
                notifyWhenComplete: settings.notifyWhenProcessingCompletes
            )
        }
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
            try environment.library.preserveLiveCaptureArtifacts(from: result, recordingID: id)
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
            if result.hasWarnings {
                importError = "The recording was saved, and its separate source tracks were preserved, but it needs attention:\n\n\(result.warnings.joined(separator: "\n"))"
            }
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
        } else if storedNavigationSelection == "libraryAsk" {
            navigationSelection = .libraryAsk
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
        case .libraryAsk: storedNavigationSelection = "libraryAsk"
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

private struct LibrarySearchKey: Hashable {
    let query: String
    let filterRaw: String
    let folder: String?
    let tag: String?
    let revisions: [LibraryRecordingRevision]
}

private struct LibraryRecordingRevision: Hashable {
    let id: UUID
    let updatedAt: Date
    let title: String
    let folder: String
    let tagsData: Data
    let isFavorite: Bool
    let processingStageRaw: String
    let segmentCount: Int
    let speakerCount: Int
    let analysisCount: Int
}

struct SearchNavigationTarget: Equatable {
    let id = UUID()
    let recordingID: UUID
    let timestamp: TimeInterval?
}

private struct RecordingRow: View {
    let recording: RecordingRecord
    let match: RecordingSearchMatch?

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
                if let match, match.kind != .title {
                    HStack(spacing: 5) {
                        Text(match.kind.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        if let timestamp = match.timestamp {
                            Text(timestamp.clockString).font(.caption2.monospacedDigit())
                        }
                        Text(match.snippet)
                            .lineLimit(2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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

private struct PackageImportConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: "shippingbox", size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore recording").font(.title2.weight(.semibold))
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("This restores a new local copy of the package, including its audio, transcript edits, speakers, notes revisions, chat, organization, and usage history. It does not upload anything.")
                .foregroundStyle(.secondary)
                .padding(16)
                .contentSurface(tint: .accentColor)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.liquidGlassButton()
                Button("Restore") {
                    onConfirm()
                    dismiss()
                }
                .liquidGlassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct LibraryWelcomeView: View {
    let recordingCount: Int
    let isSearching: Bool
    let contextTitle: String
    let matches: [RecordingSearchMatch]
    let recordings: [RecordingRecord]
    let onSelectMatch: (RecordingSearchMatch) -> Void
    let onProcessAll: () -> Void
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            SymbolBadge(symbol: "waveform.and.mic", color: .accentColor, size: 74)
            VStack(spacing: 7) {
                Text(isSearching && matches.isEmpty ? "No matching recordings" : recordingCount == 0 ? "Your conversations, made useful" : contextTitle)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(welcomeDescription)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            if isSearching && !matches.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(matches.prefix(50)) { match in
                            Button {
                                onSelectMatch(match)
                            } label: {
                                LibrarySearchMatchRow(
                                    match: match,
                                    recordingTitle: title(for: match.recordingID)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 720, maxHeight: 360)
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
                    if recordingCount > 1 && !isSearching {
                        Button("Process Visible", systemImage: "sparkles", action: onProcessAll)
                            .liquidGlassButton()
                            .controlSize(.large)
                    }
                }
            }
        }
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeDescription: String {
        if isSearching && matches.isEmpty { return "Search checks titles, transcript text, speakers, notes, action items, tags, and folders." }
        if isSearching { return "Select a result to open the recording and jump to the matching moment." }
        if recordingCount > 0 { return "Select a recording in the sidebar, or add a new conversation." }
        return "Record a meeting or import audio, then turn it into a searchable transcript, decisions, and action items."
    }

    private func title(for recordingID: UUID) -> String {
        recordings.first(where: { $0.id == recordingID })?.title ?? "Recording"
    }
}

private struct LibrarySearchMatchRow: View {
    let match: RecordingSearchMatch
    let recordingTitle: String

    private var symbol: String {
        match.kind == .transcript ? "text.bubble" : "magnifyingglass"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(recordingTitle).fontWeight(.semibold)
                Text(match.snippet).lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            if let timestamp = match.timestamp {
                Text(timestamp.clockString).font(.caption.monospacedDigit())
            }
        }
        .padding(12)
        .contentSurface()
    }
}
