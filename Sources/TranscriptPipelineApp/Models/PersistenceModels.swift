import Foundation
import SwiftData

@Model
final class RecordingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var importedAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var localAudioPath: String
    var sourceFormat: String
    var languageHintRaw: String
    var processingStageRaw: String
    var processingProgress: Double
    var lastError: String?
    var providerID: String
    var transcriptionModel: String
    var insightModel: String
    var selectedTemplateID: String
    var authorizationConfirmed: Bool
    var rawProviderResponse: Data?
    var usageData: Data
    var completedChunkIndexesData: Data

    @Relationship(deleteRule: .cascade) var segments: [TranscriptSegmentRecord]
    @Relationship(deleteRule: .cascade) var speakers: [SpeakerRecord]
    @Relationship(deleteRule: .cascade) var analyses: [AnalysisRevisionRecord]
    @Relationship(deleteRule: .cascade) var chatMessages: [ChatMessageRecord]

    init(
        id: UUID = UUID(),
        title: String,
        importedAt: Date = Date(),
        durationSeconds: Double,
        localAudioPath: String,
        sourceFormat: String,
        languageHint: LanguageHint = .automatic,
        authorizationConfirmed: Bool
    ) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.updatedAt = importedAt
        self.durationSeconds = durationSeconds
        self.localAudioPath = localAudioPath
        self.sourceFormat = sourceFormat
        self.languageHintRaw = languageHint.rawValue
        self.processingStageRaw = ProcessingStage.imported.rawValue
        self.processingProgress = 0
        self.providerID = "openai"
        self.transcriptionModel = "gpt-4o-transcribe-diarize"
        self.insightModel = "gpt-5.6-luna"
        self.selectedTemplateID = "general-meeting"
        self.authorizationConfirmed = authorizationConfirmed
        self.usageData = Data()
        self.completedChunkIndexesData = Data()
        self.segments = []
        self.speakers = []
        self.analyses = []
        self.chatMessages = []
    }

    var processingStage: ProcessingStage {
        get { ProcessingStage(rawValue: processingStageRaw) ?? .failed }
        set { processingStageRaw = newValue.rawValue }
    }

    var languageHint: LanguageHint {
        get { LanguageHint(rawValue: languageHintRaw) ?? .automatic }
        set { languageHintRaw = newValue.rawValue }
    }

    var audioURL: URL { URL(fileURLWithPath: localAudioPath) }

    var sortedSegments: [TranscriptSegmentRecord] {
        segments.sorted { lhs, rhs in
            if lhs.startSeconds == rhs.startSeconds { return lhs.endSeconds < rhs.endSeconds }
            return lhs.startSeconds < rhs.startSeconds
        }
    }

    var sortedAnalyses: [AnalysisRevisionRecord] {
        analyses.sorted { $0.createdAt > $1.createdAt }
    }

    var currentAnalysis: AnalysisRevisionRecord? { sortedAnalyses.first }

    var sortedChatMessages: [ChatMessageRecord] {
        chatMessages.sorted { $0.createdAt < $1.createdAt }
    }

    var usageEntries: [UsageEntry] {
        get { (try? JSONCoding.decoder.decode([UsageEntry].self, from: usageData)) ?? [] }
        set { usageData = (try? JSONCoding.encoder.encode(newValue)) ?? Data() }
    }

    var completedChunkIndexes: Set<Int> {
        get {
            let values = (try? JSONCoding.decoder.decode([Int].self, from: completedChunkIndexesData)) ?? []
            return Set(values)
        }
        set {
            completedChunkIndexesData = (try? JSONCoding.encoder.encode(newValue.sorted())) ?? Data()
        }
    }

    func addUsage(_ entry: UsageEntry) {
        var entries = usageEntries
        entries.append(entry)
        usageEntries = entries
    }

    func markAnalysesStale() {
        analyses.forEach { $0.isStale = true }
        updatedAt = Date()
    }
}

@Model
final class TranscriptSegmentRecord {
    @Attribute(.unique) var id: UUID
    var speakerID: String
    var startSeconds: Double
    var endSeconds: Double
    var originalText: String
    var editedText: String
    var updatedAt: Date

    init(value: TranscriptSegmentValue) {
        self.id = value.id
        self.speakerID = value.speakerID
        self.startSeconds = value.startSeconds
        self.endSeconds = value.endSeconds
        self.originalText = value.text
        self.editedText = value.text
        self.updatedAt = Date()
    }

    var effectiveText: String {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? originalText : trimmed
    }

    var value: TranscriptSegmentValue {
        TranscriptSegmentValue(
            id: id,
            speakerID: speakerID,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: effectiveText
        )
    }
}

@Model
final class SpeakerRecord {
    @Attribute(.unique) var id: UUID
    var providerLabel: String
    var displayName: String
    var colorIndex: Int

    init(id: UUID = UUID(), providerLabel: String, displayName: String, colorIndex: Int) {
        self.id = id
        self.providerLabel = providerLabel
        self.displayName = displayName
        self.colorIndex = colorIndex
    }
}

@Model
final class AnalysisRevisionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var templateID: String
    var providerID: String
    var modelID: String
    var documentData: Data
    var usageData: Data
    var isStale: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        templateID: String,
        providerID: String,
        modelID: String,
        document: AnalysisDocument,
        usage: TokenUsage,
        isStale: Bool = false
    ) throws {
        self.id = id
        self.createdAt = createdAt
        self.templateID = templateID
        self.providerID = providerID
        self.modelID = modelID
        self.documentData = try JSONCoding.encoder.encode(document)
        self.usageData = try JSONCoding.encoder.encode(usage)
        self.isStale = isStale
    }

    var document: AnalysisDocument? {
        get { try? JSONCoding.decoder.decode(AnalysisDocument.self, from: documentData) }
        set {
            guard let newValue else { return }
            documentData = (try? JSONCoding.encoder.encode(newValue)) ?? documentData
        }
    }

    var usage: TokenUsage {
        (try? JSONCoding.decoder.decode(TokenUsage.self, from: usageData)) ?? .zero
    }
}

@Model
final class ChatMessageRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var roleRaw: String
    var content: String
    var citationsData: Data
    var providerID: String
    var modelID: String
    var usageData: Data

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        role: ChatRole,
        content: String,
        citations: [EvidenceCitation] = [],
        providerID: String,
        modelID: String,
        usage: TokenUsage = .zero
    ) {
        self.id = id
        self.createdAt = createdAt
        self.roleRaw = role.rawValue
        self.content = content
        self.citationsData = (try? JSONCoding.encoder.encode(citations)) ?? Data()
        self.providerID = providerID
        self.modelID = modelID
        self.usageData = (try? JSONCoding.encoder.encode(usage)) ?? Data()
    }

    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .assistant }
    var citations: [EvidenceCitation] {
        (try? JSONCoding.decoder.decode([EvidenceCitation].self, from: citationsData)) ?? []
    }
    var usage: TokenUsage {
        (try? JSONCoding.decoder.decode(TokenUsage.self, from: usageData)) ?? .zero
    }
}

@Model
final class CustomTemplateRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var instructions: String
    var sectionGuidanceData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        sectionGuidance: [String]
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.sectionGuidanceData = (try? JSONCoding.encoder.encode(sectionGuidance)) ?? Data()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var sectionGuidance: [String] {
        get { (try? JSONCoding.decoder.decode([String].self, from: sectionGuidanceData)) ?? [] }
        set { sectionGuidanceData = (try? JSONCoding.encoder.encode(newValue)) ?? Data() }
    }

    var definition: AnalysisTemplateDefinition {
        AnalysisTemplateDefinition(
            id: id.uuidString,
            name: name,
            systemImage: "slider.horizontal.3",
            instructions: instructions,
            sectionGuidance: sectionGuidance,
            isCustom: true
        )
    }
}
