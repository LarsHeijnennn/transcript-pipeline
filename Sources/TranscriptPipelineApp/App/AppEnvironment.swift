import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let keychain: KeychainService
    let library: ManagedLibrary
    let audioPreparation: AudioPreparationService
    let liveRecording: LiveRecordingService
    let openAI: OpenAIProvider
    let processing: ProcessingCoordinator

    init() {
        do {
            let library = try ManagedLibrary()
            let audio = AudioPreparationService()
            let provider = OpenAIProvider()
            self.keychain = KeychainService()
            self.library = library
            self.audioPreparation = audio
            self.liveRecording = try LiveRecordingService(
                captureRoot: library.rootURL.appendingPathComponent("LiveCaptures", isDirectory: true)
            )
            self.openAI = provider
            self.processing = ProcessingCoordinator(
                keychain: KeychainService(),
                library: library,
                audioPreparation: audio,
                provider: provider
            )
        } catch {
            fatalError("Unable to initialize app services: \(error.localizedDescription)")
        }
    }
}
