import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var environment: AppEnvironment
    @Query(sort: \CustomTemplateRecord.createdAt) private var customTemplates: [CustomTemplateRecord]

    @State private var apiKey = ""
    @State private var revealKey = false
    @State private var keyStatus: KeyStatus = .unknown
    @State private var validationError: String?
    @State private var templateName = ""
    @State private var templateInstructions = ""
    @State private var templateSections = ""

    var body: some View {
        ZStack {
            AppCanvas()
            Form {
            Section {
                HStack(spacing: 14) {
                    SymbolBadge(symbol: "slider.horizontal.3", size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcript Pipeline").font(.title2.weight(.semibold))
                        Text("Private local library, bring-your-own OpenAI account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Developed by Lars Heijnen")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("OpenAI API") {
                HStack {
                    Group {
                        if revealKey {
                            TextField("API key", text: $apiKey)
                        } else {
                            SecureField("API key", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(revealKey ? "Hide" : "Show") { revealKey.toggle() }
                        .liquidGlassButton()
                }
                .glassControlPlate(cornerRadius: 13, horizontalPadding: 8, verticalPadding: 6)
                HStack {
                    LiquidGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Save in Keychain") { Task { await saveKey() } }
                                .liquidGlassButton(prominent: true)
                                .disabled(apiKey.trimmed.isEmpty || keyStatus == .checking)
                            Button("Validate") { Task { await validateKey() } }
                                .liquidGlassButton()
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyStatus == .checking)
                            if keyStatus != .unknown {
                                Button("Remove", role: .destructive) {
                                    apiKey = ""
                                    Task { await saveKey() }
                                }
                                .liquidGlassButton()
                                .tint(.red)
                                .disabled(keyStatus == .checking)
                            }
                        }
                    }
                    Spacer()
                    Label(keyStatus.title, systemImage: keyStatus.symbol)
                        .foregroundStyle(keyStatus.color)
                }
                if let validationError {
                    Text(validationError).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Defaults") {
                Picker("Recording language", selection: $settings.defaultLanguage) {
                    ForEach(LanguageHint.allCases) { hint in
                        Text(hint.title).tag(hint)
                    }
                }
                .glassControlPlate(cornerRadius: 12, horizontalPadding: 7, verticalPadding: 4)
                Text("Used as the starting choice for new recordings and imports. Automatic detection is recommended for mixed-language conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Insight model") {
                Picker("Default", selection: $settings.insightModel) {
                    Text("Efficient — gpt-5.6-luna").tag(AppConfiguration.defaultInsightModel)
                    Text("Higher quality — gpt-5.6-terra").tag(AppConfiguration.qualityInsightModel)
                }
                .glassControlPlate(cornerRadius: 12, horizontalPadding: 7, verticalPadding: 4)
                TextField("Advanced custom model ID", text: $settings.customModelID)
                Text("A custom ID overrides the picker. Transcription always uses \(AppConfiguration.transcriptionModel) in version 1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom analysis template") {
                TextField("Name", text: $templateName)
                TextField("Instructions", text: $templateInstructions, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Sections, separated by commas", text: $templateSections)
                Button("Add Template", systemImage: "plus") { addTemplate() }
                    .liquidGlassButton()
                    .disabled(templateName.trimmed.isEmpty || templateInstructions.trimmed.isEmpty)
                ForEach(customTemplates) { template in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(template.name).fontWeight(.medium)
                            Text(template.instructions).lineLimit(1).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            modelContext.delete(template)
                            try? modelContext.save()
                        }
                        .liquidGlassButton()
                        .tint(.red)
                        .labelStyle(.iconOnly)
                    }
                }
            }

            Section("Privacy and cost") {
                Text("The API key is stored only in macOS Keychain. OpenAI receives selected audio for transcription and transcript text plus questions for notes or chat. The original audio and library remain local.")
                Text("Live recordings are written to the local library first. Microphone and selected Mac app audio are not sent anywhere until you explicitly click Process on that recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("OpenAI says API data is not used for training by default. Its current endpoint table lists no abuse-monitoring or application-state retention for audio transcriptions. Responses may retain abuse-monitoring logs for up to 30 days; store=false disables application-state storage, not those logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("OpenAI data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                Text("Costs shown in the app are estimates from a bundled table updated \(AppConfiguration.pricingUpdatedAt). Token usage is the authoritative record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Authorization is confirmed separately for every recording.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .task { await loadKey() }
    }

    private func loadKey() async {
        do {
            apiKey = try await environment.keychain.loadAPIKeyAsync() ?? ""
            keyStatus = apiKey.isEmpty ? .unknown : .saved
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func saveKey() async {
        do {
            keyStatus = .checking
            try await environment.keychain.saveAPIKeyAsync(apiKey)
            keyStatus = apiKey.trimmed.isEmpty ? .unknown : .saved
            validationError = nil
        } catch {
            keyStatus = .invalid
            validationError = error.localizedDescription
        }
    }

    private func validateKey() async {
        keyStatus = .checking
        do {
            try await environment.openAI.validateAPIKey(apiKey)
            try await environment.keychain.saveAPIKeyAsync(apiKey)
            keyStatus = .valid
            validationError = nil
        } catch {
            keyStatus = .invalid
            validationError = error.localizedDescription
        }
    }

    private func addTemplate() {
        let sections = templateSections.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        modelContext.insert(
            CustomTemplateRecord(
                name: templateName.trimmed,
                instructions: templateInstructions.trimmed,
                sectionGuidance: sections
            )
        )
        try? modelContext.save()
        templateName = ""
        templateInstructions = ""
        templateSections = ""
    }
}

private enum KeyStatus: Equatable {
    case unknown, saved, checking, valid, invalid

    var title: String {
        switch self {
        case .unknown: "No key saved"
        case .saved: "Saved"
        case .checking: "Checking…"
        case .valid: "Key valid"
        case .invalid: "Needs attention"
        }
    }
    var symbol: String {
        switch self {
        case .unknown: "key"
        case .saved: "key.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .valid: "checkmark.seal.fill"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch self {
        case .valid: .green
        case .invalid: .orange
        default: .secondary
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
