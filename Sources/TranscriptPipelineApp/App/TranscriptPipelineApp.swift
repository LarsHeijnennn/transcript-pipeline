import SwiftData
import SwiftUI

@main
struct TranscriptPipelineApp: App {
    private let modelContainer: ModelContainer
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
        } catch {
            fatalError("Unable to initialize the local library: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(environment)
                .frame(minWidth: 820, minHeight: 600)
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
