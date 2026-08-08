import Foundation

protocol TranscriptionProvider {
    var providerID: String { get }
    var capabilities: ProviderCapabilities { get }

    func transcribe(
        part: PreparedAudioPart,
        languageHint: LanguageHint,
        knownSpeakers: [KnownSpeakerReference],
        apiKey: String
    ) async throws -> TranscriptionResult
}

protocol InsightProvider {
    func generateAnalysis(
        transcript: [TranscriptSegmentValue],
        speakers: [String: String],
        template: AnalysisTemplateDefinition,
        model: String,
        apiKey: String
    ) async throws -> (AnalysisDocument, TokenUsage)
}

protocol ChatProvider {
    func answer(
        question: String,
        transcript: [TranscriptSegmentValue],
        speakers: [String: String],
        history: [(ChatRole, String)],
        model: String,
        apiKey: String
    ) async throws -> ChatAnswer
}

enum ProviderError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case uploadTooLarge(Int)
    case unsupportedResponse
    case refused(String)
    case api(status: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI API key in Settings before processing."
        case .invalidAPIKey:
            "OpenAI rejected this API key. Check it in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter { "OpenAI rate limit reached. Try again in about \(Int(retryAfter)) seconds." }
            else { "OpenAI rate limit reached. Try again shortly." }
        case .uploadTooLarge(let bytes):
            "Prepared upload is too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case .unsupportedResponse:
            "OpenAI returned a response this app could not understand."
        case .refused(let reason):
            "OpenAI did not produce the requested output: \(reason)"
        case .api(let status, let message):
            "OpenAI error \(status): \(message)"
        case .transport(let message):
            "Network error: \(message)"
        }
    }
}

enum TranscriptFormatter {
    static func providerText(
        segments: [TranscriptSegmentValue],
        speakers: [String: String]
    ) -> String {
        segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { segment in
                let speaker = speakers[segment.speakerID] ?? segment.speakerID
                return "[\(segment.id.uuidString)] [\(segment.startSeconds.clockString)-\(segment.endSeconds.clockString)] \(speaker): \(segment.text)"
            }
            .joined(separator: "\n")
    }
}
