import Foundation

enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case imported
    case preparing
    case uploading
    case transcribing
    case merging
    case generatingNotes
    case complete
    case failed
    case cancelled

    var title: String {
        switch self {
        case .imported: "Ready"
        case .preparing: "Preparing"
        case .uploading: "Uploading"
        case .transcribing: "Transcribing"
        case .merging: "Merging"
        case .generatingNotes: "Generating notes"
        case .complete: "Complete"
        case .failed: "Needs attention"
        case .cancelled: "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .imported: "tray.and.arrow.down"
        case .preparing: "waveform"
        case .uploading: "arrow.up.circle"
        case .transcribing: "text.bubble"
        case .merging: "arrow.triangle.merge"
        case .generatingNotes: "sparkles"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .uploading, .transcribing, .merging, .generatingNotes: true
        default: false
        }
    }
}

enum LanguageHint: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case dutch = "nl"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .dutch: "Dutch"
        case .english: "English"
        }
    }

    var apiValue: String? { self == .automatic ? nil : rawValue }
}

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ProviderCapabilities: Codable, Equatable, Sendable {
    let acceptsAudio: Bool
    let supportsDiarization: Bool
    let supportsStructuredOutput: Bool
    let maximumUploadBytes: Int
    let maximumKnownSpeakers: Int
}

struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int

    static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)

    var totalTokens: Int { inputTokens + outputTokens }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens
        )
    }
}

struct UsageEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let operation: String
    let provider: String
    let model: String
    let usage: TokenUsage
    let estimatedCostUSD: Decimal?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        operation: String,
        provider: String,
        model: String,
        usage: TokenUsage,
        estimatedCostUSD: Decimal?
    ) {
        self.id = id
        self.date = date
        self.operation = operation
        self.provider = provider
        self.model = model
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
    }
}

struct TranscriptSegmentValue: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var speakerID: String
    var startSeconds: Double
    var endSeconds: Double
    var text: String

    init(
        id: UUID = UUID(),
        speakerID: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

struct KnownSpeakerReference: Sendable {
    let name: String
    let audioURL: URL
}

struct PreparedAudioPart: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let startSeconds: Double
    let endSeconds: Double
    let nominalStartSeconds: Double
    let partIndex: Int

    init(
        id: UUID = UUID(),
        fileURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        nominalStartSeconds: Double,
        partIndex: Int
    ) {
        self.id = id
        self.fileURL = fileURL
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.nominalStartSeconds = nominalStartSeconds
        self.partIndex = partIndex
    }
}

struct TranscriptionResult: Codable, Equatable, Sendable {
    let segments: [TranscriptSegmentValue]
    let detectedLanguage: String?
    let usage: TokenUsage
    let rawResponse: Data?
}

struct EvidenceCitation: Codable, Equatable, Hashable, Identifiable, Sendable {
    let segmentID: UUID
    let startSeconds: Double
    let endSeconds: Double

    var id: UUID { segmentID }
}

struct CitedText: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var citations: [EvidenceCitation]

    init(id: UUID = UUID(), text: String, citations: [EvidenceCitation] = []) {
        self.id = id
        self.text = text
        self.citations = citations
    }
}

struct AnalysisSection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var heading: String
    var items: [CitedText]

    init(id: UUID = UUID(), heading: String, items: [CitedText]) {
        self.id = id
        self.heading = heading
        self.items = items
    }
}

struct ActionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var task: String
    var owner: String
    var dueDate: String
    var isCompleted: Bool
    var citations: [EvidenceCitation]

    init(
        id: UUID = UUID(),
        task: String,
        owner: String = "",
        dueDate: String = "",
        isCompleted: Bool = false,
        citations: [EvidenceCitation] = []
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.citations = citations
    }

    private enum CodingKeys: String, CodingKey {
        case id, task, owner, dueDate, isCompleted, citations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try values.decode(String.self, forKey: .task)
        owner = try values.decodeIfPresent(String.self, forKey: .owner) ?? ""
        dueDate = try values.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        citations = try values.decodeIfPresent([EvidenceCitation].self, forKey: .citations) ?? []
    }
}

struct AnalysisDocument: Codable, Equatable, Sendable {
    var title: String
    var overview: String
    var sections: [AnalysisSection]
    var decisions: [CitedText]
    var actionItems: [ActionItem]
    var openQuestions: [CitedText]
}

struct ChatAnswer: Codable, Equatable, Sendable {
    let answer: String
    let citations: [EvidenceCitation]
    let usage: TokenUsage
}

enum LibrarySmartFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites
    case needsProcessing
    case staleNotes
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All recordings"
        case .favorites: "Favorites"
        case .needsProcessing: "Needs processing"
        case .staleNotes: "Stale notes"
        case .failed: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .all: "waveform"
        case .favorites: "star"
        case .needsProcessing: "sparkles"
        case .staleNotes: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        }
    }
}

enum SearchMatchKind: String, Sendable {
    case title, transcript, notes, speaker, tag, folder, actionItem

    var title: String {
        switch self {
        case .title: "Title"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .speaker: "Speaker"
        case .tag: "Tag"
        case .folder: "Folder"
        case .actionItem: "Action item"
        }
    }
}

struct RecordingSearchMatch: Identifiable, Sendable {
    let id: String
    let recordingID: UUID
    let kind: SearchMatchKind
    let snippet: String
    let timestamp: TimeInterval?
    let score: Int
}

struct LibraryEvidence: Identifiable, Sendable {
    let recordingID: UUID
    let recordingTitle: String
    let segment: TranscriptSegmentValue
    let speakerName: String
    let score: Double

    var id: String { "\(recordingID.uuidString)|\(segment.id.uuidString)" }
}

struct LibrarySourceCitation: Codable, Equatable, Identifiable, Sendable {
    let recordingID: UUID
    let recordingTitle: String
    let segmentID: UUID
    let startSeconds: Double
    let endSeconds: Double

    var id: String { "\(recordingID.uuidString)|\(segmentID.uuidString)" }
}

struct LibraryAnswer: Sendable {
    let answer: String
    let sources: [LibrarySourceCitation]
    let usage: TokenUsage
    let excerptCount: Int
}

struct AnalysisTemplateDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let systemImage: String
    let instructions: String
    let sectionGuidance: [String]
    let isCustom: Bool

    static let builtIns: [AnalysisTemplateDefinition] = [
        .init(
            id: "general-meeting",
            name: "General meeting",
            systemImage: "person.3",
            instructions: "Capture the purpose, key points, concrete decisions, owners, due dates, and unresolved questions. Distinguish proposals from decisions.",
            sectionGuidance: ["Purpose and context", "Key points", "Risks and dependencies"],
            isCustom: false
        ),
        .init(
            id: "lecture",
            name: "Lecture / study notes",
            systemImage: "graduationcap",
            instructions: "Explain key concepts, definitions, examples, arguments, and questions for further study. Preserve useful terminology.",
            sectionGuidance: ["Key concepts", "Definitions and examples", "Study questions"],
            isCustom: false
        ),
        .init(
            id: "interview",
            name: "Interview",
            systemImage: "mic",
            instructions: "Organize the interview by themes, claims, supporting examples, notable quotations, and follow-up questions.",
            sectionGuidance: ["Themes", "Claims and evidence", "Notable moments"],
            isCustom: false
        ),
        .init(
            id: "brainstorm",
            name: "Brainstorm",
            systemImage: "lightbulb",
            instructions: "Group ideas by theme, identify promising directions, assumptions, constraints, decisions, and concrete experiments.",
            sectionGuidance: ["Ideas by theme", "Promising directions", "Constraints and experiments"],
            isCustom: false
        )
    ]
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension TimeInterval {
    var clockString: String {
        let total = max(0, Int(self.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
