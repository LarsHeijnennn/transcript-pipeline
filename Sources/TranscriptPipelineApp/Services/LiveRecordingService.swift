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
            "Records the microphone you choose. Useful for in-person conversations and speakerphone calls."
        case .macAudioAndMicrophone:
            "Records audio from the Mac app you choose, plus your selected microphone. Use this for Teams, Zoom, FaceTime, or calls routed through the Mac."
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
        case .choosingContent: "Choose a Mac app"
        case .starting: "Starting and checking sources…"
        case .recording: "Recording"
        case .stopping: "Finishing and checking recording…"
        }
    }
}

enum LiveAudioSource: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "Mac app audio"
        }
    }

    var filename: String {
        switch self {
        case .microphone: "microphone.m4a"
        case .systemAudio: "mac-audio.m4a"
        }
    }
}

enum LiveAudioHealth: Equatable, Sendable {
    case waiting
    case active
    case silent
    case stalled
    case failed(String)
}

struct LiveAudioSourceStatus: Equatable, Sendable {
    let source: LiveAudioSource
    var health: LiveAudioHealth
    var level: Double
    var detail: String
    var hasDetectedSound: Bool

    static func waiting(_ source: LiveAudioSource) -> LiveAudioSourceStatus {
        LiveAudioSourceStatus(
            source: source,
            health: .waiting,
            level: 0,
            detail: "Waiting for audio samples",
            hasDetectedSound: false
        )
    }
}

struct LiveMicrophoneDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct LiveRecordingArtifact: Codable, Hashable, Sendable {
    let source: LiveAudioSource
    let fileURL: URL
    let durationSeconds: TimeInterval
    let firstSampleTimeSeconds: TimeInterval?
    let firstSampleWallClockSeconds: TimeInterval?
    let maxRMS: Double
    let averageAudibleRMS: Double
    let receivedBufferCount: Int
    let writtenBufferCount: Int
    let droppedBufferCount: Int

    var containsAudibleAudio: Bool { maxRMS >= AudioLevelMeter.audibleRMSThreshold }
}

struct LiveRecordingResult: Sendable {
    let fileURL: URL
    let durationSeconds: TimeInterval
    let mode: LiveRecordingMode
    let sourceArtifacts: [LiveRecordingArtifact]
    let diagnosticsURL: URL?
    let warnings: [String]

    var hasWarnings: Bool { !warnings.isEmpty }
}

enum LiveRecordingError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable(String)
    case contentSelectionCancelled
    case alreadyRecording
    case notRecording
    case systemAudioUnavailable(String)
    case requiredAudioMissing(String)
    case writerFailed(String)
    case exportFailed(String)
    case noUsableAudio(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required. Enable What Was Said in System Settings → Privacy & Security → Microphone."
        case .microphoneUnavailable(let detail):
            "The selected microphone is unavailable: \(detail)"
        case .contentSelectionCancelled:
            "No Mac app was selected."
        case .alreadyRecording:
            "A recording is already active."
        case .notRecording:
            "There is no active recording to stop."
        case .systemAudioUnavailable(let detail):
            "Mac audio capture could not start: \(detail)"
        case .requiredAudioMissing(let source):
            "\(source) did not produce a readable audio track."
        case .writerFailed(let detail):
            "The recording could not be written: \(detail)"
        case .exportFailed(let detail):
            "The microphone and Mac audio could not be combined: \(detail)"
        case .noUsableAudio(let detail):
            "No usable recording could be saved. \(detail)"
        }
    }
}

@MainActor
final class LiveRecordingService: NSObject, ObservableObject {
    @Published private(set) var phase: LiveRecordingPhase = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var microphoneStatus = LiveAudioSourceStatus.waiting(.microphone)
    @Published private(set) var systemAudioStatus = LiveAudioSourceStatus.waiting(.systemAudio)
    @Published private(set) var availableMicrophones: [LiveMicrophoneDevice] = []
    @Published private(set) var selectedApplicationName = ""

    private let captureRoot: URL
    private let fileManager: FileManager
    private var captureDirectory: URL?
    private var microphoneCapture: MicrophoneCaptureSession?
    private var screenStream: SCStream?
    private var screenSink: ScreenCaptureAudioSink?
    private var selectedMode: LiveRecordingMode?
    private var selectedMicrophone: LiveMicrophoneDevice?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?
    private var sourceTelemetry: [LiveAudioSource: SourceTelemetryState] = [:]

    var defaultMicrophoneID: String? {
        availableMicrophones.first(where: \.isDefault)?.id ?? availableMicrophones.first?.id
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
        refreshMicrophones()
    }

    func refreshMicrophones() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        var seen = Set<String>()
        availableMicrophones = discovery.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return LiveMicrophoneDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func start(mode: LiveRecordingMode, microphoneDeviceID: String?) async throws {
        guard phase == .idle else { throw LiveRecordingError.alreadyRecording }
        try await requireMicrophonePermission()
        refreshMicrophones()

        guard let microphone = resolveMicrophone(id: microphoneDeviceID) else {
            throw LiveRecordingError.microphoneUnavailable("No audio input device is connected.")
        }

        selectedMode = mode
        selectedMicrophone = microphone
        selectedApplicationName = ""
        elapsedSeconds = 0
        sourceTelemetry = [:]
        microphoneStatus = .waiting(.microphone)
        systemAudioStatus = .waiting(.systemAudio)

        do {
            let filter: SCContentFilter?
            if mode.requiresScreenCapture {
                phase = .choosingContent
                let selectedFilter = try await chooseApplicationWithSystemPicker()
                filter = selectedFilter
                selectedApplicationName = selectedApplicationDescription(from: selectedFilter)
            } else {
                filter = nil
            }

            phase = .starting
            let directory = try makeCaptureDirectory()
            captureDirectory = directory
            startedAt = Date()

            if let filter {
                if #available(macOS 15.0, *) {
                    try await startUnifiedCapture(
                        filter: filter,
                        microphone: microphone,
                        directory: directory
                    )
                } else {
                    try await startSeparateMicrophoneCapture(microphone: microphone, directory: directory)
                    try await startSystemAudioOnly(filter: filter, directory: directory)
                }
            } else {
                try await startSeparateMicrophoneCapture(microphone: microphone, directory: directory)
            }

            phase = .recording
            startElapsedTimer()
        } catch {
            await abandonCurrentCapture(removeFiles: true)
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

        var outcomes: [AudioTrackFinishOutcome] = []
        if let microphoneCapture {
            outcomes.append(await microphoneCapture.stop())
            self.microphoneCapture = nil
        }

        if let screenStream {
            do {
                try await screenStream.stopCapture()
            } catch {
                screenSink?.recordFailure(error)
            }
        }
        screenStream = nil
        deactivatePicker()

        if let screenSink {
            outcomes.append(contentsOf: await screenSink.finish())
            self.screenSink = nil
        }

        do {
            var artifacts: [LiveRecordingArtifact] = []
            var warnings: [String] = outcomes.compactMap(\.issue)

            for outcome in outcomes {
                guard let draft = outcome.artifact else { continue }
                do {
                    let metadata = try await RecordedAudioValidator.metadata(
                        at: draft.fileURL,
                        source: draft.source.title
                    )
                    artifacts.append(draft.withDuration(metadata.durationSeconds))
                } catch {
                    warnings.append(error.localizedDescription)
                }
            }

            let requiredSources: Set<LiveAudioSource> = mode == .microphone
                ? [.microphone]
                : [.microphone, .systemAudio]
            warnings.append(contentsOf: CaptureQualityEvaluator.warnings(
                artifacts: artifacts,
                requiredSources: requiredSources,
                expectedDuration: duration
            ))
            warnings = Array(Set(warnings)).sorted()

            guard !artifacts.isEmpty else {
                let diagnosticsURL = try? writeDiagnostics(
                    directory: directory,
                    duration: duration,
                    artifacts: [],
                    warnings: warnings
                )
                let location = diagnosticsURL?.deletingLastPathComponent().path ?? directory.path
                resetStateKeepingCaptureFiles()
                throw LiveRecordingError.noUsableAudio("Capture diagnostics were kept at \(location).")
            }

            let finalURL: URL
            let microphoneArtifact = artifacts.first { $0.source == .microphone }
            let systemArtifact = artifacts.first { $0.source == .systemAudio }
            if let microphoneArtifact, let systemArtifact {
                finalURL = directory.appendingPathComponent("recording.m4a")
                let timedTracks = AudioTrackMerger.alignedTracks(
                    artifacts: [systemArtifact, microphoneArtifact]
                )
                try await AudioTrackMerger.merge(tracks: timedTracks, outputURL: finalURL)
                try await RecordedAudioValidator.validateTrack(at: finalURL, source: "The combined recording")
            } else if let onlyArtifact = artifacts.first {
                finalURL = onlyArtifact.fileURL
            } else {
                throw LiveRecordingError.noUsableAudio("The source files could not be finalized.")
            }

            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
            let diagnosticsURL = try writeDiagnostics(
                directory: directory,
                duration: duration,
                artifacts: artifacts,
                warnings: warnings
            )
            let result = LiveRecordingResult(
                fileURL: finalURL,
                durationSeconds: duration,
                mode: mode,
                sourceArtifacts: artifacts,
                diagnosticsURL: diagnosticsURL,
                warnings: warnings
            )
            resetStateKeepingCaptureFiles()
            return result
        } catch {
            let recoveryDirectory = directory.path
            resetStateKeepingCaptureFiles()
            if let recordingError = error as? LiveRecordingError { throw recordingError }
            throw LiveRecordingError.exportFailed(
                "\(error.localizedDescription) The separate source tracks were kept at \(recoveryDirectory)."
            )
        }
    }

    func cancel() async {
        if let pickerContinuation {
            self.pickerContinuation = nil
            pickerContinuation.resume(throwing: CancellationError())
        }
        await abandonCurrentCapture(removeFiles: true)
    }

    func discard(_ result: LiveRecordingResult) throws {
        let directory = result.fileURL.deletingLastPathComponent().standardizedFileURL
        let root = captureRoot.standardizedFileURL.path + "/"
        guard directory.path.hasPrefix(root) else { return }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func resolveMicrophone(id: String?) -> LiveMicrophoneDevice? {
        if let id, !id.isEmpty, let exact = availableMicrophones.first(where: { $0.id == id }) {
            return exact
        }
        return availableMicrophones.first(where: \.isDefault) ?? availableMicrophones.first
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

    private func chooseApplicationWithSystemPicker() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleApplication]
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

    private func selectedApplicationDescription(from filter: SCContentFilter) -> String {
        let names = filter.includedApplications.map(\.applicationName).filter { !$0.isEmpty }
        return names.first ?? "Selected Mac app"
    }

    @available(macOS 15.0, *)
    private func startUnifiedCapture(
        filter: SCContentFilter,
        microphone: LiveMicrophoneDevice,
        directory: URL
    ) async throws {
        let configuration = baseScreenConfiguration()
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphone.id

        let sink = ScreenCaptureAudioSink(
            outputURLs: [
                .systemAudio: directory.appendingPathComponent(LiveAudioSource.systemAudio.filename),
                .microphone: directory.appendingPathComponent(LiveAudioSource.microphone.filename)
            ],
            telemetryHandler: telemetryHandler
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
        } catch {
            throw LiveRecordingError.systemAudioUnavailable(error.localizedDescription)
        }
        screenSink = sink
        screenStream = stream
    }

    private func startSystemAudioOnly(filter: SCContentFilter, directory: URL) async throws {
        let sink = ScreenCaptureAudioSink(
            outputURLs: [
                .systemAudio: directory.appendingPathComponent(LiveAudioSource.systemAudio.filename)
            ],
            telemetryHandler: telemetryHandler
        )
        let stream = SCStream(filter: filter, configuration: baseScreenConfiguration(), delegate: self)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
        } catch {
            throw LiveRecordingError.systemAudioUnavailable(error.localizedDescription)
        }
        screenSink = sink
        screenStream = stream
    }

    private func baseScreenConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return configuration
    }

    private func startSeparateMicrophoneCapture(
        microphone: LiveMicrophoneDevice,
        directory: URL
    ) async throws {
        let capture = try MicrophoneCaptureSession(
            deviceID: microphone.id,
            outputURL: directory.appendingPathComponent(LiveAudioSource.microphone.filename),
            telemetryHandler: telemetryHandler
        )
        do {
            try await capture.start()
        } catch {
            _ = await capture.stop()
            throw error
        }
        microphoneCapture = capture
    }

    private var telemetryHandler: @Sendable (AudioSourceTelemetry) -> Void {
        { [weak self] telemetry in
            Task { @MainActor [weak self] in
                self?.receiveTelemetry(telemetry)
            }
        }
    }

    private func receiveTelemetry(_ telemetry: AudioSourceTelemetry) {
        var state = sourceTelemetry[telemetry.source] ?? SourceTelemetryState()
        state.lastSampleWallClock = telemetry.wallClockSeconds
        if telemetry.levelRMS >= AudioLevelMeter.audibleRMSThreshold {
            state.lastAudibleWallClock = telemetry.wallClockSeconds
            state.hasDetectedSound = true
        }
        state.maxRMS = max(state.maxRMS, telemetry.maxRMS)
        state.lastRMS = telemetry.levelRMS
        state.receivedBufferCount = telemetry.receivedBufferCount
        state.writtenBufferCount = telemetry.writtenBufferCount
        state.droppedBufferCount = telemetry.droppedBufferCount
        if let failure = telemetry.failure { state.failure = failure }
        sourceTelemetry[telemetry.source] = state
        updatePublishedStatus(for: telemetry.source, currentLevel: telemetry.levelRMS)
    }

    private func updatePublishedStatus(for source: LiveAudioSource, currentLevel: Double? = nil) {
        let now = Date().timeIntervalSinceReferenceDate
        let recordingAge = Date().timeIntervalSince(startedAt ?? Date())
        let state = sourceTelemetry[source] ?? SourceTelemetryState()
        let level = currentLevel ?? state.lastRMS
        let health: LiveAudioHealth
        let detail: String

        if let failure = state.failure {
            health = .failed(failure)
            detail = failure
        } else if let lastSample = state.lastSampleWallClock, now - lastSample > 2.5 {
            health = .stalled
            detail = "Audio samples stopped arriving"
        } else if state.lastSampleWallClock == nil {
            health = recordingAge > 2.5 ? .stalled : .waiting
            detail = recordingAge > 2.5 ? "No audio samples are arriving" : "Waiting for audio samples"
        } else if !state.hasDetectedSound, recordingAge > 8 {
            health = .silent
            detail = "Samples are arriving, but no sound has been detected"
        } else if let lastAudible = state.lastAudibleWallClock,
                  now - lastAudible > 60 {
            health = .silent
            detail = "No sound detected for one minute; speak or play call audio to test this source"
        } else {
            health = .active
            detail = state.hasDetectedSound ? "Audio is arriving" : "Connected; waiting for sound"
        }

        let status = LiveAudioSourceStatus(
            source: source,
            health: health,
            level: health == .stalled ? 0 : AudioLevelMeter.displayLevel(forRMS: level),
            detail: detail,
            hasDetectedSound: state.hasDetectedSound
        )
        switch source {
        case .microphone: microphoneStatus = status
        case .systemAudio: systemAudioStatus = status
        }
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

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = floor(Date().timeIntervalSince(startedAt))
                if elapsed != self.elapsedSeconds { self.elapsedSeconds = elapsed }
                self.updatePublishedStatus(for: .microphone)
                if self.selectedMode == .macAudioAndMicrophone {
                    self.updatePublishedStatus(for: .systemAudio)
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

    private func abandonCurrentCapture(removeFiles: Bool) async {
        stopElapsedTimer()
        if let microphoneCapture { _ = await microphoneCapture.stop() }
        self.microphoneCapture = nil
        if let screenStream { try? await screenStream.stopCapture() }
        screenStream = nil
        if let screenSink { _ = await screenSink.finish() }
        self.screenSink = nil
        deactivatePicker()
        if removeFiles, let captureDirectory, fileManager.fileExists(atPath: captureDirectory.path) {
            try? fileManager.removeItem(at: captureDirectory)
        }
        resetStateKeepingCaptureFiles()
    }

    private func resetStateKeepingCaptureFiles() {
        stopElapsedTimer()
        captureDirectory = nil
        selectedMode = nil
        selectedMicrophone = nil
        selectedApplicationName = ""
        startedAt = nil
        elapsedSeconds = 0
        sourceTelemetry = [:]
        microphoneStatus = .waiting(.microphone)
        systemAudioStatus = .waiting(.systemAudio)
        phase = .idle
    }

    private func writeDiagnostics(
        directory: URL,
        duration: TimeInterval,
        artifacts: [LiveRecordingArtifact],
        warnings: [String]
    ) throws -> URL {
        let diagnostics = LiveCaptureDiagnostics(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            mode: selectedMode?.rawValue ?? "unknown",
            selectedApplication: selectedApplicationName,
            selectedMicrophone: selectedMicrophone?.name ?? "Unknown microphone",
            expectedDurationSeconds: duration,
            artifacts: artifacts,
            warnings: warnings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(diagnostics)
        let url = directory.appendingPathComponent("capture-diagnostics.json")
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
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
            self?.screenSink?.recordFailure(error)
        }
    }
}

private struct SourceTelemetryState: Sendable {
    var lastSampleWallClock: TimeInterval?
    var lastAudibleWallClock: TimeInterval?
    var hasDetectedSound = false
    var maxRMS: Double = 0
    var lastRMS: Double = 0
    var receivedBufferCount = 0
    var writtenBufferCount = 0
    var droppedBufferCount = 0
    var failure: String?
}

private struct AudioSourceTelemetry: Sendable {
    let source: LiveAudioSource
    let wallClockSeconds: TimeInterval
    let levelRMS: Double
    let maxRMS: Double
    let receivedBufferCount: Int
    let writtenBufferCount: Int
    let droppedBufferCount: Int
    let failure: String?
}

private struct AudioTrackFinishOutcome: Sendable {
    let source: LiveAudioSource
    let artifact: LiveRecordingArtifact?
    let issue: String?
}

private final class ScreenCaptureAudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.larsheijnen.TranscriptPipeline.screen-audio", qos: .userInitiated)
    private let writers: [LiveAudioSource: AudioSampleWriter]

    init(
        outputURLs: [LiveAudioSource: URL],
        telemetryHandler: @escaping @Sendable (AudioSourceTelemetry) -> Void
    ) {
        self.writers = Dictionary(uniqueKeysWithValues: outputURLs.map { source, url in
            (source, AudioSampleWriter(
                source: source,
                outputURL: url,
                telemetryHandler: telemetryHandler
            ))
        })
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: LiveAudioSource?
        switch type {
        case .audio:
            source = .systemAudio
        case .microphone:
            source = .microphone
        default:
            source = nil
        }
        guard let source, let writer = writers[source] else { return }
        writer.append(sampleBuffer)
    }

    func recordFailure(_ error: Error) {
        queue.async { [writers] in
            for writer in writers.values {
                writer.recordFailure(error.localizedDescription)
            }
        }
    }

    func finish() async -> [AudioTrackFinishOutcome] {
        let orderedWriters = queue.sync {
            LiveAudioSource.allCases.compactMap { writers[$0] }
        }
        var outcomes: [AudioTrackFinishOutcome] = []
        for writer in orderedWriters {
            outcomes.append(await writer.finish())
        }
        return outcomes
    }
}

private final class MicrophoneCaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.larsheijnen.TranscriptPipeline.microphone-audio", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: AudioSampleWriter
    private var notificationTokens: [NSObjectProtocol] = []
    private var stopped = false
    private var restartInProgress = false
    private var restartAttempts = 0

    init(
        deviceID: String,
        outputURL: URL,
        telemetryHandler: @escaping @Sendable (AudioSourceTelemetry) -> Void
    ) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw LiveRecordingError.microphoneUnavailable("The chosen input was disconnected.")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw LiveRecordingError.microphoneUnavailable(error.localizedDescription)
        }
        self.writer = AudioSampleWriter(
            source: .microphone,
            outputURL: outputURL,
            telemetryHandler: telemetryHandler
        )
        super.init()

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw LiveRecordingError.microphoneUnavailable("macOS rejected the audio capture connection.")
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        observeSessionFailures()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [session] in
                session.startRunning()
                if session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LiveRecordingError.microphoneUnavailable("The capture session did not start."))
                }
            }
        }
    }

    func stop() async -> AudioTrackFinishOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopped else {
                    continuation.resume()
                    return
                }
                stopped = true
                output.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
                notificationTokens.removeAll()
                continuation.resume()
            }
        }
        return await writer.finish()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        restartAttempts = 0
        writer.append(sampleBuffer)
    }

    private func observeSessionFailures() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.queue.async {
                guard let self else { return }
                self.restartIfNeeded(
                    after: error?.localizedDescription ?? "The microphone capture session reported an error."
                )
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self, weak writer] _ in
            self?.queue.async {
                writer?.recordIssue("The microphone was temporarily interrupted or taken by another application.")
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                self?.restartIfNeeded(after: "The microphone interruption ended.")
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.didStopRunningNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, !self.stopped else { return }
                self.restartIfNeeded(after: "The microphone capture session stopped unexpectedly.")
            }
        })
    }

    private func restartIfNeeded(after reason: String) {
        guard !stopped else { return }
        writer.recordIssue(reason)
        guard !session.isRunning, !restartInProgress else { return }
        guard restartAttempts < 3 else {
            writer.recordFailure("The microphone could not be restarted after three attempts.")
            return
        }

        restartInProgress = true
        restartAttempts += 1
        session.startRunning()
        restartInProgress = false
        if !session.isRunning, restartAttempts >= 3 {
            writer.recordFailure("The microphone could not be restarted after three attempts.")
        }
    }
}

private final class AudioSampleWriter: @unchecked Sendable {
    let source: LiveAudioSource
    private let outputURL: URL
    private let telemetryHandler: @Sendable (AudioSourceTelemetry) -> Void
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var storedFailure: String?
    private var storedIssues: [String] = []
    private var firstSampleTimeSeconds: TimeInterval?
    private var firstSampleWallClockSeconds: TimeInterval?
    private var lastTelemetryWallClock: TimeInterval = 0
    private var maxRMS: Double = 0
    private var audibleRMSAccumulator: Double = 0
    private var audibleBufferCount = 0
    private var receivedBufferCount = 0
    private var writtenBufferCount = 0
    private var droppedBufferCount = 0
    private var finished = false

    init(
        source: LiveAudioSource,
        outputURL: URL,
        telemetryHandler: @escaping @Sendable (AudioSourceTelemetry) -> Void
    ) {
        self.source = source
        self.outputURL = outputURL
        self.telemetryHandler = telemetryHandler
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !finished,
              sampleBuffer.isValid,
              sampleBuffer.numSamples > 0,
              storedFailure == nil else { return }
        receivedBufferCount += 1
        let now = Date().timeIntervalSinceReferenceDate
        let level = AudioLevelMeter.rms(of: sampleBuffer)
        maxRMS = max(maxRMS, level)
        if level >= AudioLevelMeter.audibleRMSThreshold {
            audibleRMSAccumulator += level
            audibleBufferCount += 1
        }

        do {
            if writer == nil { try beginWriter(at: sampleBuffer.presentationTimeStamp, formatHint: sampleBuffer.formatDescription) }
            guard let input else { throw LiveRecordingError.writerFailed("The \(source.title) writer is missing.") }
            if input.isReadyForMoreMediaData {
                if input.append(sampleBuffer) {
                    writtenBufferCount += 1
                } else {
                    droppedBufferCount += 1
                    storedFailure = writer?.error?.localizedDescription ?? "An audio buffer could not be written."
                }
            } else {
                droppedBufferCount += 1
            }
        } catch {
            storedFailure = error.localizedDescription
        }

        if now - lastTelemetryWallClock >= 0.1 || receivedBufferCount == 1 || storedFailure != nil {
            lastTelemetryWallClock = now
            emitTelemetry(level: level, wallClock: now)
        }
    }

    func recordFailure(_ detail: String) {
        guard storedFailure == nil else { return }
        storedFailure = detail
        emitTelemetry(level: 0, wallClock: Date().timeIntervalSinceReferenceDate)
    }

    func recordIssue(_ detail: String) {
        guard !storedIssues.contains(detail) else { return }
        storedIssues.append(detail)
    }

    func finish() async -> AudioTrackFinishOutcome {
        guard !finished else {
            return AudioTrackFinishOutcome(source: source, artifact: nil, issue: "\(source.title) was finalized more than once.")
        }
        finished = true
        let capturedFailure = storedFailure
        let capturedIssues = storedIssues

        guard receivedBufferCount > 0, let writer, let input else {
            return AudioTrackFinishOutcome(
                source: source,
                artifact: nil,
                issue: capturedFailure ?? "\(source.title) produced no audio samples."
            )
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            return AudioTrackFinishOutcome(
                source: source,
                artifact: nil,
                issue: writer.error?.localizedDescription ?? capturedFailure ?? "\(source.title) writer stopped unexpectedly."
            )
        }

        let artifact = LiveRecordingArtifact(
            source: source,
            fileURL: outputURL,
            durationSeconds: 0,
            firstSampleTimeSeconds: firstSampleTimeSeconds,
            firstSampleWallClockSeconds: firstSampleWallClockSeconds,
            maxRMS: maxRMS,
            averageAudibleRMS: audibleBufferCount > 0 ? audibleRMSAccumulator / Double(audibleBufferCount) : 0,
            receivedBufferCount: receivedBufferCount,
            writtenBufferCount: writtenBufferCount,
            droppedBufferCount: droppedBufferCount
        )
        var issueDetails = capturedIssues
        if let capturedFailure { issueDetails.append(capturedFailure) }
        let issue = issueDetails.isEmpty ? nil : "\(source.title): \(issueDetails.joined(separator: " "))"
        return AudioTrackFinishOutcome(source: source, artifact: artifact, issue: issue)
    }

    private func beginWriter(at startTime: CMTime, formatHint: CMFormatDescription?) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        var sampleRate = 48_000
        var channelCount = source == .systemAudio ? 2 : 1
        if let audioDescription = formatHint,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription) {
            sampleRate = max(8_000, Int(description.pointee.mSampleRate.rounded()))
            channelCount = max(1, min(2, Int(description.pointee.mChannelsPerFrame)))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 80_000 : 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: formatHint
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw LiveRecordingError.writerFailed("AAC settings were rejected for \(source.title).")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw LiveRecordingError.writerFailed(writer.error?.localizedDescription ?? "The \(source.title) writer did not start.")
        }
        writer.startSession(atSourceTime: startTime)
        firstSampleTimeSeconds = startTime.seconds.isFinite ? startTime.seconds : nil
        firstSampleWallClockSeconds = Date().timeIntervalSinceReferenceDate
        self.writer = writer
        self.input = input
    }

    private func emitTelemetry(level: Double, wallClock: TimeInterval) {
        telemetryHandler(AudioSourceTelemetry(
            source: source,
            wallClockSeconds: wallClock,
            levelRMS: level,
            maxRMS: maxRMS,
            receivedBufferCount: receivedBufferCount,
            writtenBufferCount: writtenBufferCount,
            droppedBufferCount: droppedBufferCount,
            failure: storedFailure
        ))
    }
}

enum AudioLevelMeter {
    static let audibleRMSThreshold = 0.001

    static func rms(of sampleBuffer: CMSampleBuffer) -> Double {
        guard let description = sampleBuffer.formatDescription else { return 0 }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)
              ) else { return 0 }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleBuffer.numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return 0 }

        var sumSquares = 0.0
        var sampleCount = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            switch format.commonFormat {
            case .pcmFormatFloat32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let value = Double(values[index])
                    sumSquares += value * value
                }
                sampleCount += count
            case .pcmFormatFloat64:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let values = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let value = values[index]
                    sumSquares += value * value
                }
                sampleCount += count
            case .pcmFormatInt16:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let values = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int16.max)
                    sumSquares += value * value
                }
                sampleCount += count
            case .pcmFormatInt32:
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let values = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int32.max)
                    sumSquares += value * value
                }
                sampleCount += count
            case .otherFormat:
                break
            @unknown default:
                break
            }
        }
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Double(sampleCount))
    }

    static func displayLevel(forRMS rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

struct RecordedAudioMetadata: Sendable {
    let durationSeconds: TimeInterval
}

enum RecordedAudioValidator {
    static func metadata(at url: URL, source: String) async throws -> RecordedAudioMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LiveRecordingError.requiredAudioMissing(source)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw LiveRecordingError.requiredAudioMissing(source)
        }
        return RecordedAudioMetadata(durationSeconds: duration)
    }

    static func validateTrack(at url: URL, source: String) async throws {
        _ = try await metadata(at: url, source: source)
    }
}

enum CaptureQualityEvaluator {
    static func warnings(
        artifacts: [LiveRecordingArtifact],
        requiredSources: Set<LiveAudioSource>,
        expectedDuration: TimeInterval
    ) -> [String] {
        var warnings: [String] = []
        for source in requiredSources {
            guard let artifact = artifacts.first(where: { $0.source == source }) else {
                warnings.append("\(source.title) was not available; the other source was preserved.")
                continue
            }
            if !artifact.containsAudibleAudio {
                warnings.append("\(source.title) contained samples but no audible sound was detected.")
            }
            if expectedDuration >= 5,
               artifact.durationSeconds < expectedDuration - 3,
               artifact.durationSeconds / expectedDuration < 0.9 {
                warnings.append(
                    "\(source.title) stopped early at \(artifact.durationSeconds.clockString) of \(expectedDuration.clockString)."
                )
            }
            let materialDropThreshold = max(5, Int(Double(artifact.receivedBufferCount) * 0.001))
            if artifact.droppedBufferCount > materialDropThreshold {
                warnings.append(
                    "\(source.title) dropped \(artifact.droppedBufferCount) audio buffer\(artifact.droppedBufferCount == 1 ? "" : "s") while writing."
                )
            }
        }
        return warnings
    }
}

struct TimedAudioTrack: Sendable {
    let url: URL
    let startOffset: TimeInterval
    let volume: Float
}

enum AudioTrackMerger {
    static func alignedTracks(artifacts: [LiveRecordingArtifact]) -> [TimedAudioTrack] {
        let presentationStarts = artifacts.compactMap(\.firstSampleTimeSeconds)
        let presentationSpread = (presentationStarts.max() ?? 0) - (presentationStarts.min() ?? 0)
        let presentationTimesAreComparable = presentationStarts.count == artifacts.count
            && presentationSpread.isFinite
            && presentationSpread <= 5
        let wallClockStarts = artifacts.compactMap(\.firstSampleWallClockSeconds)
        let earliestPresentationTime = presentationTimesAreComparable ? presentationStarts.min() : nil
        let earliestWallClockTime = wallClockStarts.min()

        return artifacts.map { artifact in
            let offset: TimeInterval
            if let first = artifact.firstSampleTimeSeconds, let earliestPresentationTime {
                offset = min(max(first - earliestPresentationTime, 0), 5)
            } else if let first = artifact.firstSampleWallClockSeconds, let earliestWallClockTime {
                offset = min(max(first - earliestWallClockTime, 0), 5)
            } else {
                offset = 0
            }
            return TimedAudioTrack(
                url: artifact.fileURL,
                startOffset: offset,
                volume: mixingVolume(for: artifact.averageAudibleRMS)
            )
        }
    }

    static func merge(audioURLs: [URL], outputURL: URL) async throws {
        try await merge(
            tracks: audioURLs.map { TimedAudioTrack(url: $0, startOffset: 0, volume: 0.78) },
            outputURL: outputURL
        )
    }

    static func merge(tracks: [TimedAudioTrack], outputURL: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []

        for item in tracks {
            let asset = AVURLAsset(url: item.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let timeRange = try await sourceTrack.load(.timeRange)
            guard timeRange.duration.seconds.isFinite, timeRange.duration.seconds > 0,
                  let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            try destinationTrack.insertTimeRange(
                timeRange,
                of: sourceTrack,
                at: CMTime(seconds: item.startOffset, preferredTimescale: 48_000)
            )
            let inputParameters = AVMutableAudioMixInputParameters(track: destinationTrack)
            inputParameters.setVolume(item.volume, at: .zero)
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
        if #available(macOS 15.0, *) {
            do {
                try await exporter.export(to: outputURL, as: .m4a)
            } catch {
                throw LiveRecordingError.exportFailed(error.localizedDescription)
            }
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            await exporter.export()
            guard exporter.status == .completed else {
                throw LiveRecordingError.exportFailed(exporter.error?.localizedDescription ?? "Export stopped unexpectedly.")
            }
        }
    }

    private static func mixingVolume(for audibleRMS: Double) -> Float {
        guard audibleRMS >= AudioLevelMeter.audibleRMSThreshold else { return 0.78 }
        let targetRMS = 0.08
        return Float(min(max((targetRMS / audibleRMS) * 0.78, 0.4), 0.9))
    }
}

private struct LiveCaptureDiagnostics: Codable, Sendable {
    let createdAt: Date
    let appVersion: String
    let mode: String
    let selectedApplication: String
    let selectedMicrophone: String
    let expectedDurationSeconds: TimeInterval
    let artifacts: [LiveRecordingArtifact]
    let warnings: [String]
}

private extension LiveRecordingArtifact {
    func withDuration(_ duration: TimeInterval) -> LiveRecordingArtifact {
        LiveRecordingArtifact(
            source: source,
            fileURL: fileURL,
            durationSeconds: duration,
            firstSampleTimeSeconds: firstSampleTimeSeconds,
            firstSampleWallClockSeconds: firstSampleWallClockSeconds,
            maxRMS: maxRMS,
            averageAudibleRMS: averageAudibleRMS,
            receivedBufferCount: receivedBufferCount,
            writtenBufferCount: writtenBufferCount,
            droppedBufferCount: droppedBufferCount
        )
    }
}
