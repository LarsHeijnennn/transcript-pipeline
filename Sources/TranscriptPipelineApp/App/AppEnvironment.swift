import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let startupWarning: String?
    let keychain: KeychainService
    let library: ManagedLibrary
    let audioPreparation: AudioPreparationService
    let liveRecording: LiveRecordingService
    let openAI: OpenAIProvider
    let processing: ProcessingCoordinator

    init() {
        let components: Components
        do {
            components = try Self.makeComponents(rootURL: nil, warning: nil)
        } catch {
            let warning = "The normal managed library could not be opened: \(error.localizedDescription). This session is using a temporary recovery library."
            let recoveryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptPipeline-Recovery-\(UUID().uuidString)", isDirectory: true)
            do {
                components = try Self.makeComponents(rootURL: recoveryRoot, warning: warning)
            } catch {
                preconditionFailure("Unable to create even a temporary recovery library: \(error.localizedDescription)")
            }
        }
        self.startupWarning = components.warning
        self.keychain = components.keychain
        self.library = components.library
        self.audioPreparation = components.audio
        self.liveRecording = components.liveRecording
        self.openAI = components.provider
        self.processing = components.processing
    }

    private struct Components {
        let warning: String?
        let keychain: KeychainService
        let library: ManagedLibrary
        let audio: AudioPreparationService
        let liveRecording: LiveRecordingService
        let provider: OpenAIProvider
        let processing: ProcessingCoordinator
    }

    private static func makeComponents(rootURL: URL?, warning: String?) throws -> Components {
        let library = try ManagedLibrary(rootURL: rootURL)
        let audio = AudioPreparationService()
        let provider = OpenAIProvider()
        let keychain = KeychainService()
        let liveRecording = try LiveRecordingService(
            captureRoot: library.rootURL.appendingPathComponent("LiveCaptures", isDirectory: true)
        )
        let processing = ProcessingCoordinator(
            keychain: keychain,
            library: library,
            audioPreparation: audio,
            provider: provider
        )
        return Components(
            warning: warning,
            keychain: keychain,
            library: library,
            audio: audio,
            liveRecording: liveRecording,
            provider: provider,
            processing: processing
        )
    }
}
