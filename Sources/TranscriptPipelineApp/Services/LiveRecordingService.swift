@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation

enum LiveRecordingMode: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case macAudioAndMicrophone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .macAudioAndMicrophone: "Mac app + microphone"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            "Records the selected Mac microphone. Useful for in-person conversations and speakerphone calls."
        case .macAudioAndMicrophone:
            "Records audio from an app or window you choose in Apple’s picker, plus your microphone. Use this for Teams, Zoom, FaceTime, or calls routed through the Mac."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .macAudioAndMicrophone: "macbook.and.iphone"
        }
    }

    var requiresScreenCapture: Bool { self == .macAudioAndMicrophone }
}

enum LiveRecordingPhase: Equatable, Sendable {
    case idle
    case choosingContent
    case starting
    case recording
    case stopping

    var isBusy: Bool { self != .idle }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .choosingContent: "Choose an app or window"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .stopping: "Finishing recording…"
        }
    }
}

struct LiveRecordingResult: Sendable {
    let fileURL: URL
    let durationSeconds: TimeInterval
    let mode: LiveRecordingMode
}

enum LiveRecordingError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable
    case contentSelectionCancelled
    case alreadyRecording
    case notRecording
    case systemAudioUnavailable(String)
    case requiredAudioMissing(String)
    case writerFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required. Enable What Was Said in System Settings → Privacy & Security → Microphone."
        case .microphoneUnavailable:
            "The selected microphone is unavailable. Check the Mac’s Sound input settings and try again."
        case .contentSelectionCancelled:
            "No Mac app or window was selected."
        case .alreadyRecording:
            "A recording is already active."
        case .notRecording:
            "There is no active recording to stop."
        case .systemAudioUnavailable(let detail):
            "Mac audio capture could not start: \(detail)"
        case .requiredAudioMissing(let source):
            "\(source) did not produce a readable audio track. The recording was not saved."
        case .writerFailed(let detail):
            "The recording could not be written: \(detail)"
        case .exportFailed(let detail):
            "The microphone and Mac audio could not be combined: \(detail)"
        }
    }
}

@MainActor
final class LiveRecordingService: NSObject, ObservableObject {
    @Published private(set) var phase: LiveRecordingPhase = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var systemAudioDetected = false

    private let captureRoot: URL
    private let fileManager: FileManager
    private var captureDirectory: URL?
    private var microphoneRecorder: AVAudioRecorder?
    private var systemStream: SCStream?
    private var systemSink: SystemAudioCaptureSink?
    private var selectedMode: LiveRecordingMode?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?

    var activeSourceSummary: String {
        switch selectedMode {
        case .macAudioAndMicrophone:
            systemAudioDetected
                ? "Microphone and selected Mac app audio are being captured"
                : "Microphone active; waiting for audio from the selected Mac app"
        case .microphone:
            "Microphone is being captured"
        case nil:
            ""
        }
    }

    init(captureRoot: URL, fileManager: FileManager = .default) throws {
        self.captureRoot = captureRoot
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: captureRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        super.init()
    }

    func start(mode: LiveRecordingMode) async throws {
        guard phase == .idle else { throw LiveRecordingError.alreadyRecording }
        try await requireMicrophonePermission()
        selectedMode = mode
        elapsedSeconds = 0
        systemAudioDetected = false

        do {
            let filter: SCContentFilter?
            if mode.requiresScreenCapture {
                phase = .choosingContent
                filter = try await chooseContentWithSystemPicker()
            } else {
                filter = nil
            }

            phase = .starting
            let directory = try makeCaptureDirectory()
            captureDirectory = directory
            let microphoneURL = directory.appendingPathComponent("microphone.m4a")
            microphoneRecorder = try makeMicrophoneRecorder(outputURL: microphoneURL)
            guard microphoneRecorder?.record() == true else {
                throw LiveRecordingError.microphoneUnavailable
            }

            if let filter {
                try await startSystemAudio(filter: filter, outputURL: directory.appendingPathComponent("mac-audio.m4a"))
            }

            startedAt = Date()
            phase = .recording
            startElapsedTimer()
        } catch {
            await abandonCurrentCapture()
            throw error
        }
    }

    func stop() async throws -> LiveRecordingResult {
        guard phase == .recording, let mode = selectedMode, let directory = captureDirectory else {
            throw LiveRecordingError.notRecording
        }
        phase = .stopping
        stopElapsedTimer()
        let duration = max(elapsedSeconds, Date().timeIntervalSince(startedAt ?? Date()))

        microphoneRecorder?.stop()
        microphoneRecorder = nil

        if let systemStream {
            do {
                try await systemStream.stopCapture()
            } catch {
                await abandonCurrentCapture()
                throw LiveRecordingError.systemAudioUnavailable(error.localizedDescription)
            }
        }
        systemStream = nil
        deactivatePicker()

        do {
            let microphoneURL = directory.appendingPathComponent("microphone.m4a")
            try await RecordedAudioValidator.validateTrack(at: microphoneURL, source: "The microphone")

            let finalURL: URL
            switch mode {
            case .microphone:
                finalURL = microphoneURL
            case .macAudioAndMicrophone:
                guard let sink = systemSink else {
                    throw LiveRecordingError.requiredAudioMissing("The selected Mac app")
                }
                systemSink = nil
                let systemURL = try await sink.finish()
                try await RecordedAudioValidator.validateTrack(at: systemURL, source: "The selected Mac app")

                finalURL = directory.appendingPathComponent("recording.m4a")
                try await AudioTrackMerger.merge(
                    audioURLs: [systemURL, microphoneURL],
                    outputURL: finalURL
                )
                try await RecordedAudioValidator.validateTrack(at: finalURL, source: "The combined recording")
            }

            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
            phase = .idle
            selectedMode = nil
            startedAt = nil
            elapsedSeconds = 0
            systemAudioDetected = false
            return LiveRecordingResult(fileURL: finalURL, durationSeconds: duration, mode: mode)
        } catch {
            await abandonCurrentCapture()
            throw error
        }
    }

    func cancel() async {
        if let pickerContinuation {
            self.pickerContinuation = nil
            pickerContinuation.resume(throwing: CancellationError())
        }
        await abandonCurrentCapture()
    }

    func discard(_ result: LiveRecordingResult) throws {
        let directory = result.fileURL.deletingLastPathComponent().standardizedFileURL
        let root = captureRoot.standardizedFileURL.path + "/"
        guard directory.path.hasPrefix(root) else { return }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func requireMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw LiveRecordingError.microphoneDenied
            }
        default:
            throw LiveRecordingError.microphoneDenied
        }
    }

    private func chooseContentWithSystemPicker() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleApplication, .singleWindow]
        configuration.excludedBundleIDs = [AppConfiguration.bundleIdentifier]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true

        return try await withCheckedThrowingContinuation { continuation in
            pickerContinuation = continuation
            picker.present()
        }
    }

    private func startSystemAudio(filter: SCContentFilter, outputURL: URL) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sink = SystemAudioCaptureSink(outputURL: outputURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.systemAudioDetected = true
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
        } catch {
            throw LiveRecordingError.systemAudioUnavailable(error.localizedDescription)
        }
        systemSink = sink
        systemStream = stream
    }

    private func makeCaptureDirectory() throws -> URL {
        let directory = captureRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func makeMicrophoneRecorder(outputURL: URL) throws -> AVAudioRecorder {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else { throw LiveRecordingError.microphoneUnavailable }
        return recorder
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = floor(Date().timeIntervalSince(startedAt))
                if elapsed != self.elapsedSeconds {
                    self.elapsedSeconds = elapsed
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func deactivatePicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func abandonCurrentCapture() async {
        stopElapsedTimer()
        microphoneRecorder?.stop()
        microphoneRecorder = nil
        if let systemStream { try? await systemStream.stopCapture() }
        systemStream = nil
        _ = try? await systemSink?.finish()
        systemSink = nil
        deactivatePicker()
        if let captureDirectory, fileManager.fileExists(atPath: captureDirectory.path) {
            try? fileManager.removeItem(at: captureDirectory)
        }
        captureDirectory = nil
        selectedMode = nil
        startedAt = nil
        elapsedSeconds = 0
        systemAudioDetected = false
        phase = .idle
    }

    private func receivePickerFilter(_ filter: SCContentFilter) {
        guard let pickerContinuation else { return }
        self.pickerContinuation = nil
        pickerContinuation.resume(returning: filter)
    }

    private func receivePickerCancellation(_ error: Error = LiveRecordingError.contentSelectionCancelled) {
        guard let pickerContinuation else { return }
        self.pickerContinuation = nil
        pickerContinuation.resume(throwing: error)
    }
}

extension LiveRecordingService: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in self?.receivePickerFilter(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.receivePickerCancellation() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.receivePickerCancellation(error) }
    }
}

extension LiveRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.systemSink?.recordFailure(error)
        }
    }
}

private final class SystemAudioCaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.larsheijnen.TranscriptPipeline.system-audio")
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var storedError: Error?
    private var receivedSamples = false
    private let onFirstSample: @Sendable () -> Void

    init(outputURL: URL, onFirstSample: @escaping @Sendable () -> Void) {
        self.outputURL = outputURL
        self.onFirstSample = onFirstSample
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0, storedError == nil else { return }
        do {
            if writer == nil { try beginWriter(at: sampleBuffer.presentationTimeStamp) }
            guard let input, input.isReadyForMoreMediaData else { return }
            if !input.append(sampleBuffer) {
                storedError = writer?.error ?? LiveRecordingError.writerFailed("Audio buffer append failed.")
            } else if !receivedSamples {
                receivedSamples = true
                onFirstSample()
            }
        } catch {
            storedError = error
        }
    }

    func recordFailure(_ error: Error) {
        queue.async { [weak self] in
            guard let self, self.storedError == nil else { return }
            self.storedError = LiveRecordingError.systemAudioUnavailable(error.localizedDescription)
        }
    }

    func finish() async throws -> URL {
        let snapshot: (AVAssetWriter?, AVAssetWriterInput?, Error?, Bool) = queue.sync {
            (writer, input, storedError, receivedSamples)
        }
        let (writerValue, inputValue, error, hasSamples) = snapshot
        if let error { throw error }
        guard hasSamples, let writer = writerValue, let input = inputValue else {
            throw LiveRecordingError.requiredAudioMissing("The selected Mac app")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LiveRecordingError.writerFailed(writer.error?.localizedDescription ?? "System audio writer stopped unexpectedly.")
        }
        return outputURL
    }

    private func beginWriter(at startTime: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw LiveRecordingError.writerFailed("AAC settings were rejected.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw LiveRecordingError.writerFailed(writer.error?.localizedDescription ?? "Writer did not start.")
        }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        self.input = input
    }
}

enum RecordedAudioValidator {
    static func validateTrack(at url: URL, source: String) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LiveRecordingError.requiredAudioMissing(source)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw LiveRecordingError.requiredAudioMissing(source)
        }
    }
}

enum AudioTrackMerger {
    static func merge(
        audioURLs: [URL],
        outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []

        for url in audioURLs {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
            let inputParameters = AVMutableAudioMixInputParameters(track: destinationTrack)
            inputParameters.setVolume(0.78, at: .zero)
            parameters.append(inputParameters)
        }

        guard !parameters.isEmpty else {
            throw LiveRecordingError.exportFailed("No readable audio tracks were produced.")
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw LiveRecordingError.exportFailed("The AAC exporter is unavailable.")
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        exporter.audioMix = audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        await exporter.export()
        guard exporter.status == .completed else {
            throw LiveRecordingError.exportFailed(exporter.error?.localizedDescription ?? "Export stopped unexpectedly.")
        }
    }
}
