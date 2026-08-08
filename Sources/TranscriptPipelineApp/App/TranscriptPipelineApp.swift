import SwiftData
import SwiftUI

@main
struct TranscriptPipelineApp: App {
    private let modelContainer: ModelContainer
    private let modelStartupError: String?
    @StateObject private var settings = AppSettings()
    @StateObject private var environment = AppEnvironment()

    init() {
        do {
            modelContainer = try ModelContainer(
                for: RecordingRecord.self,
                TranscriptSegmentRecord.self,
                SpeakerRecord.self,
                AnalysisRevisionRecord.self,
                ChatMessageRecord.self,
                CustomTemplateRecord.self
            )
            modelStartupError = nil
        } catch {
            modelStartupError = error.localizedDescription
            do {
                modelContainer = try ModelContainer(
                    for: RecordingRecord.self,
                    TranscriptSegmentRecord.self,
                    SpeakerRecord.self,
                    AnalysisRevisionRecord.self,
                    ChatMessageRecord.self,
                    CustomTemplateRecord.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                preconditionFailure("Unable to initialize a temporary recovery database: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(environment)
                .frame(minWidth: 820, minHeight: 600)
                .overlay(alignment: .top) {
                    if let error = modelStartupError ?? environment.startupWarning {
                        StartupRecoveryBanner(message: error)
                    }
                }
        }
        .modelContainer(modelContainer)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(environment)
                .modelContainer(modelContainer)
                .frame(width: 620, height: 560)
        }
    }
}

private struct StartupRecoveryBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovery mode").font(.callout.weight(.semibold))
                Text(message).font(.caption).lineLimit(2)
            }
            Spacer()
            Button("Copy details") { NativeSharing.copy(message) }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }
}
