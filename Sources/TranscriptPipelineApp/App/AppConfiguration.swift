import Foundation
import SwiftUI

enum AppConfiguration {
    static let displayName = "Transcript Pipeline"
    static let bundleIdentifier = "nl.larsheijnen.TranscriptPipeline"
    static let keychainService = bundleIdentifier
    static let keychainAccount = "openai-api-key"
    static let maximumRecordingDuration: TimeInterval = 3 * 60 * 60
    static let maximumUploadBytes = 24 * 1_024 * 1_024
    static let transcriptionModel = "gpt-4o-transcribe-diarize"
    static let defaultInsightModel = "gpt-5.6-luna"
    static let qualityInsightModel = "gpt-5.6-terra"
    static let pricingUpdatedAt = "2026-08-07"
    static let archiveExtension = "transcriptpipeline"
    static let archiveSchemaVersion = 1
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/LarsHeijnennn/transcript-pipeline/releases/latest")!
    static let supportedExtensions: Set<String> = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var insightModel: String {
        didSet { defaults.set(insightModel, forKey: Keys.insightModel) }
    }
    @Published var customModelID: String {
        didSet { defaults.set(customModelID, forKey: Keys.customModelID) }
    }
    @Published var defaultLanguage: LanguageHint {
        didSet { defaults.set(defaultLanguage.rawValue, forKey: Keys.defaultLanguage) }
    }
    @Published var hasAcknowledgedPrivacy: Bool {
        didSet { defaults.set(hasAcknowledgedPrivacy, forKey: Keys.privacyAcknowledged) }
    }
    @Published var notifyWhenProcessingCompletes: Bool {
        didSet { defaults.set(notifyWhenProcessingCompletes, forKey: Keys.notifyWhenProcessingCompletes) }
    }
    @Published var automaticallyCheckForUpdates: Bool {
        didSet { defaults.set(automaticallyCheckForUpdates, forKey: Keys.automaticallyCheckForUpdates) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.insightModel = defaults.string(forKey: Keys.insightModel) ?? AppConfiguration.defaultInsightModel
        self.customModelID = defaults.string(forKey: Keys.customModelID) ?? ""
        self.defaultLanguage = LanguageHint(rawValue: defaults.string(forKey: Keys.defaultLanguage) ?? "") ?? .automatic
        self.hasAcknowledgedPrivacy = defaults.bool(forKey: Keys.privacyAcknowledged)
        self.notifyWhenProcessingCompletes = defaults.object(forKey: Keys.notifyWhenProcessingCompletes) as? Bool ?? true
        self.automaticallyCheckForUpdates = defaults.object(forKey: Keys.automaticallyCheckForUpdates) as? Bool ?? true
    }

    var resolvedInsightModel: String {
        let trimmed = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? insightModel : trimmed
    }

    private enum Keys {
        static let insightModel = "insightModel"
        static let customModelID = "customModelID"
        static let defaultLanguage = "defaultLanguage"
        static let privacyAcknowledged = "privacyAcknowledged"
        static let notifyWhenProcessingCompletes = "notifyWhenProcessingCompletes"
        static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    }
}

enum PricingCatalog {
    struct Rate: Sendable {
        let inputPerMillion: Decimal
        let outputPerMillion: Decimal
    }

    // Deliberately dated estimates. Token counts remain authoritative when vendor prices change.
    static let rates: [String: Rate] = [
        "gpt-4o-transcribe-diarize": Rate(inputPerMillion: 2.50, outputPerMillion: 10.00),
        "gpt-5.6-luna": Rate(inputPerMillion: 0.20, outputPerMillion: 1.20)
    ]

    static func estimate(model: String, usage: TokenUsage) -> Decimal? {
        guard let rate = rates[model] else { return nil }
        let input = Decimal(usage.inputTokens) / 1_000_000 * rate.inputPerMillion
        let output = Decimal(usage.outputTokens) / 1_000_000 * rate.outputPerMillion
        return input + output
    }
}
