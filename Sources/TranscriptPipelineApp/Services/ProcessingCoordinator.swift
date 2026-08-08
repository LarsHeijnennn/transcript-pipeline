import Foundation
import SwiftData
import UserNotifications

@MainActor
final class ProcessingCoordinator: ObservableObject {
    @Published private(set) var activeRecordingIDs: Set<UUID> = []
    @Published private(set) var queuedRecordingIDs: [UUID] = []

    private struct ProcessingJob {
        let recording: RecordingRecord
        let template: AnalysisTemplateDefinition
        let insightModel: String
        let modelContext: ModelContext
        let notifyWhenComplete: Bool
    }

    private var pendingJobs: [ProcessingJob] = []
    private var activeTask: Task<Void, Never>?

    private let keychain: KeychainService
    private let library: ManagedLibrary
    private let audioPreparation: AudioPreparationService
    private let provider: OpenAIProvider

    init(
        keychain: KeychainService,
        library: ManagedLibrary,
        audioPreparation: AudioPreparationService,
        provider: OpenAIProvider
    ) {
        self.keychain = keychain
        self.library = library
        self.audioPreparation = audioPreparation
        self.provider = provider
    }

    func enqueue(
        recording: RecordingRecord,
        template: AnalysisTemplateDefinition,
        insightModel: String,
        modelContext: ModelContext,
        notifyWhenComplete: Bool = true
    ) {
        guard !activeRecordingIDs.contains(recording.id),
              !queuedRecordingIDs.contains(recording.id) else { return }
        recording.processingStage = .preparing
        recording.processingProgress = 0.01
        recording.processingDetail = activeTask == nil ? "Starting…" : "Waiting in processing queue"
        try? modelContext.save()
        pendingJobs.append(ProcessingJob(
            recording: recording,
            template: template,
            insightModel: insightModel,
            modelContext: modelContext,
            notifyWhenComplete: notifyWhenComplete
        ))
        queuedRecordingIDs.append(recording.id)
        startNextJobIfNeeded()
    }

    func cancel(recordingID: UUID) {
        if activeRecordingIDs.contains(recordingID) {
            activeTask?.cancel()
            return
        }
        guard let index = pendingJobs.firstIndex(where: { $0.recording.id == recordingID }) else { return }
        let job = pendingJobs.remove(at: index)
        queuedRecordingIDs.removeAll { $0 == recordingID }
        job.recording.processingStage = .cancelled
        job.recording.processingDetail = "Removed from queue"
        job.recording.lastError = "Processing was cancelled before it started."
        try? job.modelContext.save()
    }

    func queuePosition(for recordingID: UUID) -> Int? {
        queuedRecordingIDs.firstIndex(of: recordingID).map { $0 + 1 }
    }

    private func startNextJobIfNeeded() {
        guard activeTask == nil, !pendingJobs.isEmpty else { return }
        let job = pendingJobs.removeFirst()
        queuedRecordingIDs.removeAll { $0 == job.recording.id }
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.process(
                recording: job.recording,
                template: job.template,
                insightModel: job.insightModel,
                modelContext: job.modelContext
            )
            if job.notifyWhenComplete {
                await self.postCompletionNotification(for: job.recording)
            }
            self.activeTask = nil
            self.startNextJobIfNeeded()
        }
    }

    func process(
        recording: RecordingRecord,
        template: AnalysisTemplateDefinition,
        insightModel: String,
        modelContext: ModelContext
    ) async {
        guard !activeRecordingIDs.contains(recording.id) else { return }
        activeRecordingIDs.insert(recording.id)
        defer { activeRecordingIDs.remove(recording.id) }

        do {
            guard recording.authorizationConfirmed else {
                throw ProcessingError.authorizationNotConfirmed
            }
            guard FileManager.default.fileExists(atPath: recording.localAudioPath) else {
                throw ManagedLibraryError.missingRecording
            }
            guard let apiKey = try await keychain.loadAPIKeyAsync(), !apiKey.isEmpty else {
                throw ProviderError.missingAPIKey
            }

            recording.lastError = nil
            recording.insightModel = insightModel
            recording.selectedTemplateID = template.id
            recording.processingStage = .preparing
            recording.processingProgress = 0.04
            recording.processingDetail = "Preparing audio locally"
            try modelContext.save()

            let workingDirectory = try library.workingDirectory(for: recording.id)
            let parts = try await audioPreparation.prepare(
                sourceURL: recording.audioURL,
                duration: recording.durationSeconds,
                workingDirectory: workingDirectory
            )
            var partTranscriptions: [PartTranscription] = []
            var completed = recording.completedChunkIndexes

            for part in parts {
                try Task.checkCancellation()
                let checkpointURL = checkpointURL(for: part.partIndex, directory: workingDirectory)
                if completed.contains(part.partIndex),
                   let data = try? Data(contentsOf: checkpointURL),
                   let result = try? JSONCoding.decoder.decode(TranscriptionResult.self, from: data) {
                    partTranscriptions.append(PartTranscription(part: part, result: result))
                    recording.processingDetail = "Reused saved part \(part.partIndex + 1) of \(parts.count)"
                    continue
                }

                recording.processingStage = .uploading
                recording.processingProgress = 0.10 + 0.65 * Double(part.partIndex) / Double(max(1, parts.count))
                recording.processingDetail = "Uploading part \(part.partIndex + 1) of \(parts.count)"
                try modelContext.save()

                let references: [KnownSpeakerReference]
                if let first = partTranscriptions.first {
                    references = await makeReferences(
                        firstPart: first,
                        sourceURL: recording.audioURL,
                        workingDirectory: workingDirectory
                    )
                } else {
                    references = []
                }

                recording.processingStage = .transcribing
                recording.processingDetail = "Transcribing part \(part.partIndex + 1) of \(parts.count)"
                let result = try await provider.transcribe(
                    part: part,
                    languageHint: recording.languageHint,
                    knownSpeakers: references,
                    apiKey: apiKey
                )
                let checkpointData = try JSONCoding.encoder.encode(result)
                try checkpointData.write(to: checkpointURL, options: [.atomic, .completeFileProtection])
                completed.insert(part.partIndex)
                recording.completedChunkIndexes = completed
                partTranscriptions.append(PartTranscription(part: part, result: result))
                try modelContext.save()
            }

            recording.processingStage = .merging
            recording.processingProgress = 0.78
            recording.processingDetail = "Combining transcript parts"
            let merged = TranscriptMerger.merge(partTranscriptions)
            replaceTranscript(recording: recording, merged: merged, modelContext: modelContext)
            // Checkpoints cover crash recovery. Keeping a second full provider transcript in SwiftData
            // doubles storage and forces large blobs through the observation graph for no product benefit.
            recording.rawProviderResponse = nil
            let transcriptionCost = PricingCatalog.estimate(
                model: AppConfiguration.transcriptionModel,
                usage: merged.usage
            )
            recording.addUsage(
                UsageEntry(
                    operation: "Transcription",
                    provider: provider.providerID,
                    model: AppConfiguration.transcriptionModel,
                    usage: merged.usage,
                    estimatedCostUSD: transcriptionCost
                )
            )
            try modelContext.save()

            recording.processingStage = .generatingNotes
            recording.processingProgress = 0.86
            recording.processingDetail = "Generating grounded notes"
            try modelContext.save()
            try await createAnalysis(
                recording: recording,
                template: template,
                model: insightModel,
                apiKey: apiKey,
                modelContext: modelContext
            )

            recording.processingStage = .complete
            recording.processingProgress = 1
            recording.processingDetail = "Finished"
            recording.completedChunkIndexes = []
            recording.updatedAt = Date()
            try modelContext.save()
            try? library.clearWorkingDirectory(for: recording.id)
        } catch is CancellationError {
            recording.processingStage = .cancelled
            recording.processingDetail = "Cancelled; completed parts are saved"
            recording.lastError = "Processing was cancelled. Completed chunks remain available for retry."
            try? modelContext.save()
        } catch {
            recording.processingStage = .failed
            recording.processingDetail = "Stopped with an error"
            recording.lastError = error.localizedDescription
            try? modelContext.save()
        }
    }

    func regenerateAnalysis(
        recording: RecordingRecord,
        template: AnalysisTemplateDefinition,
        insightModel: String,
        modelContext: ModelContext
    ) async throws {
        guard let apiKey = try await keychain.loadAPIKeyAsync(), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }
        recording.processingStage = .generatingNotes
        recording.processingProgress = 0.88
        recording.processingDetail = "Generating a new notes revision"
        try modelContext.save()
        do {
            try await createAnalysis(
                recording: recording,
                template: template,
                model: insightModel,
                apiKey: apiKey,
                modelContext: modelContext
            )
            recording.processingStage = .complete
            recording.processingProgress = 1
            recording.processingDetail = "Finished"
            try modelContext.save()
        } catch {
            recording.processingStage = .failed
            recording.processingDetail = "Notes generation failed"
            recording.lastError = error.localizedDescription
            try? modelContext.save()
            throw error
        }
    }

    func sendQuestion(
        _ question: String,
        recording: RecordingRecord,
        insightModel: String,
        modelContext: ModelContext
    ) async throws {
        guard let apiKey = try await keychain.loadAPIKeyAsync(), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessageRecord(
            role: .user,
            content: trimmed,
            providerID: "local",
            modelID: "none"
        )
        recording.chatMessages.append(userMessage)
        try modelContext.save()

        let priorHistory = recording.sortedChatMessages.dropLast().map { ($0.role, $0.content) }
        do {
            let answer = try await provider.answer(
                question: trimmed,
                transcript: recording.sortedSegments.map(\.value),
                speakers: speakerNames(recording),
                history: priorHistory,
                model: insightModel,
                apiKey: apiKey
            )
            let assistant = ChatMessageRecord(
                role: .assistant,
                content: answer.answer,
                citations: answer.citations,
                providerID: provider.providerID,
                modelID: insightModel,
                usage: answer.usage
            )
            recording.chatMessages.append(assistant)
            recording.addUsage(
                UsageEntry(
                    operation: "Recording chat",
                    provider: provider.providerID,
                    model: insightModel,
                    usage: answer.usage,
                    estimatedCostUSD: PricingCatalog.estimate(model: insightModel, usage: answer.usage)
                )
            )
            try modelContext.save()
        } catch {
            modelContext.delete(userMessage)
            try? modelContext.save()
            throw error
        }
    }

    func answerLibraryQuestion(
        _ question: String,
        recordings: [RecordingRecord],
        insightModel: String
    ) async throws -> LibraryAnswer {
        guard let apiKey = try await keychain.loadAPIKeyAsync(), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }
        let documents = LibraryRetrievalEngine.documents(from: recordings)
        let retrievalTask = Task.detached(priority: .userInitiated) {
            LibraryRetrievalEngine.evidence(for: question, documents: documents)
        }
        let evidence = await withTaskCancellationHandler {
            await retrievalTask.value
        } onCancel: {
            retrievalTask.cancel()
        }
        try Task.checkCancellation()
        return try await provider.answerLibrary(
            question: question,
            evidence: evidence,
            model: insightModel,
            apiKey: apiKey
        )
    }

    private func createAnalysis(
        recording: RecordingRecord,
        template: AnalysisTemplateDefinition,
        model: String,
        apiKey: String,
        modelContext: ModelContext
    ) async throws {
        let (document, usage) = try await provider.generateAnalysis(
            transcript: recording.sortedSegments.map(\.value),
            speakers: speakerNames(recording),
            template: template,
            model: model,
            apiKey: apiKey
        )
        recording.analyses.forEach { $0.isStale = true }
        let revision = try AnalysisRevisionRecord(
            templateID: template.id,
            providerID: provider.providerID,
            modelID: model,
            document: document,
            usage: usage
        )
        recording.analyses.append(revision)
        recording.addUsage(
            UsageEntry(
                operation: "Analysis",
                provider: provider.providerID,
                model: model,
                usage: usage,
                estimatedCostUSD: PricingCatalog.estimate(model: model, usage: usage)
            )
        )
        try modelContext.save()
    }

    private func replaceTranscript(
        recording: RecordingRecord,
        merged: MergedTranscript,
        modelContext: ModelContext
    ) {
        recording.segments.forEach(modelContext.delete)
        recording.speakers.forEach(modelContext.delete)
        recording.segments = merged.segments.map(TranscriptSegmentRecord.init)
        recording.speakers = merged.speakerDisplayNames
            .sorted { $0.key < $1.key }
            .enumerated()
            .map { index, pair in
                SpeakerRecord(providerLabel: pair.key, displayName: pair.value, colorIndex: index)
            }
        recording.markAnalysesStale()
    }

    private func speakerNames(_ recording: RecordingRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.providerLabel, $0.displayName) })
    }

    private func makeReferences(
        firstPart: PartTranscription,
        sourceURL: URL,
        workingDirectory: URL
    ) async -> [KnownSpeakerReference] {
        var labels: [String] = []
        for segment in firstPart.result.segments where !labels.contains(segment.speakerID) {
            labels.append(segment.speakerID)
        }
        var references: [KnownSpeakerReference] = []
        for (index, label) in labels.prefix(4).enumerated() {
            let candidates = firstPart.result.segments.filter {
                $0.speakerID == label && ($0.endSeconds - $0.startSeconds) >= 2
            }
            guard var best = candidates.max(by: {
                ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds)
            }) else { continue }
            best.startSeconds += firstPart.part.startSeconds
            best.endSeconds += firstPart.part.startSeconds
            if let reference = try? await audioPreparation.makeSpeakerReference(
                sourceURL: sourceURL,
                segment: best,
                name: "speaker-\(index + 1)",
                workingDirectory: workingDirectory
            ) {
                references.append(reference)
            }
        }
        return references
    }

    private func checkpointURL(for index: Int, directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "result-%03d.json", index))
    }

    private func postCompletionNotification(for recording: RecordingRecord) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = recording.processingStage == .complete ? "Recording ready" : "Recording needs attention"
        content.body = recording.processingStage == .complete
            ? "\(recording.title) has been transcribed and summarized."
            : "\(recording.title) stopped: \(recording.lastError ?? "Unknown error")"
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: "processing-\(recording.id.uuidString)",
            content: content,
            trigger: nil
        ))
    }
}

enum ProcessingError: LocalizedError {
    case authorizationNotConfirmed

    var errorDescription: String? {
        "Confirm that you are permitted to process this recording before sending it to an API."
    }
}
