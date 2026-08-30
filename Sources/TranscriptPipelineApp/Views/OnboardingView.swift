import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var apiKey = ""
    @State private var keyMessage: String?
    @State private var validating = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: privacyPage
                case 1: keyPage
                default: readyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("\(page + 1) of 3").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }.liquidGlassButton()
                }
                if page < 2 {
                    Button(page == 1 ? "Continue" : "Get Started") { page += 1 }
                        .liquidGlassButton(prominent: true)
                } else {
                    Button("Open What Was Said") {
                        settings.hasAcknowledgedPrivacy = true
                        dismiss()
                    }
                    .liquidGlassButton(prominent: true)
                }
            }
            .padding(20)
        }
        .frame(width: 680, height: 520)
        .task { apiKey = (try? await environment.keychain.loadAPIKeyAsync()) ?? "" }
    }

    private var privacyPage: some View {
        VStack(spacing: 24) {
            SymbolBadge(symbol: "waveform.and.mic", size: 72)
            Text("Your recordings stay yours").font(.largeTitle.weight(.semibold))
            Text("What Was Said keeps audio, transcripts, edits, notes, and chat in a managed library on this Mac. Nothing is uploaded when you record or import.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            HStack(spacing: 14) {
                OnboardingCard(symbol: "internaldrive", title: "Local library", detail: "Your originals and work products remain on this Mac.")
                OnboardingCard(symbol: "hand.tap", title: "Explicit processing", detail: "Audio leaves only when you click Process.")
                OnboardingCard(symbol: "lock.shield", title: "Your API key", detail: "Stored in macOS Keychain, never in exports.")
            }
        }
        .padding(34)
    }

    private var keyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                SymbolBadge(symbol: "key", size: 52)
                VStack(alignment: .leading) {
                    Text("Connect OpenAI").font(.largeTitle.weight(.semibold))
                    Text("Bring your own API account; there is no What Was Said account.")
                        .foregroundStyle(.secondary)
                }
            }
            SecureField("OpenAI API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save and validate") { Task { await validateKey() } }
                    .liquidGlassButton(prominent: true)
                    .disabled(apiKey.trimmed.isEmpty || validating)
                if validating { ProgressView().controlSize(.small) }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Text("You can skip this and add a key later in Settings. Importing and recording work without a key; processing does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(42)
    }

    private var readyPage: some View {
        VStack(spacing: 24) {
            SymbolBadge(symbol: "checkmark.seal", color: .green, size: 72)
            Text("Ready when you are").font(.largeTitle.weight(.semibold))
            Text("Record a microphone or Mac audio, import multiple files, or restore a complete recording package. You’ll confirm permission separately for every new recording.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: 12) {
                Label("⌘O imports audio or recording packages", systemImage: "square.and.arrow.down")
                Label("⇧⌘R starts a local recording", systemImage: "record.circle")
                Label("Search includes transcripts, notes, speakers, and tasks", systemImage: "magnifyingglass")
            }
            .font(.callout)
        }
        .padding(42)
    }

    private func validateKey() async {
        validating = true
        defer { validating = false }
        do {
            try await environment.openAI.validateAPIKey(apiKey)
            try await environment.keychain.saveAPIKeyAsync(apiKey)
            keyMessage = "Key validated and saved in Keychain."
        } catch {
            keyMessage = error.localizedDescription
        }
    }
}

private struct OnboardingCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(title).fontWeight(.semibold)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .contentSurface()
    }
}
