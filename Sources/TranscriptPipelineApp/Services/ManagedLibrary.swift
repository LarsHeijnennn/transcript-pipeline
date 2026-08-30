import AVFoundation
import Foundation

enum ManagedLibraryError: LocalizedError {
    case unsupportedFormat(String)
    case recordingTooLong(TimeInterval)
    case unreadableAudio
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported audio format: .\(ext)."
        case .recordingTooLong(let duration):
            return "This recording is \(duration.clockString). Version 1 supports recordings up to three hours."
        case .unreadableAudio:
            return "The recording could not be read by macOS."
        case .missingRecording:
            return "The managed recording file is missing."
        }
    }
}

struct ImportedRecording: Sendable {
    let managedURL: URL
    let durationSeconds: Double
    let sourceFormat: String
    let suggestedTitle: String
}

struct ManagedLibrary: @unchecked Sendable {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootURL = support
                .appendingPathComponent(AppConfiguration.displayName, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func importFile(from sourceURL: URL, recordingID: UUID) async throws -> ImportedRecording {
        let ext = sourceURL.pathExtension.lowercased()
        guard AppConfiguration.supportedExtensions.contains(ext) else {
            throw ManagedLibraryError.unsupportedFormat(ext)
        }

        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasSecurityAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ManagedLibraryError.unreadableAudio }
        guard duration <= AppConfiguration.maximumRecordingDuration else {
            throw ManagedLibraryError.recordingTooLong(duration)
        }

        let directory = recordingDirectory(for: recordingID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("original.\(ext)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        return ImportedRecording(
            managedURL: destination,
            durationSeconds: duration,
            sourceFormat: ext,
            suggestedTitle: sourceURL.deletingPathExtension().lastPathComponent
        )
    }

    func recordingDirectory(for recordingID: UUID) -> URL {
        rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    func preserveLiveCaptureArtifacts(from result: LiveRecordingResult, recordingID: UUID) throws {
        guard result.mode == .macAudioAndMicrophone || result.hasWarnings else { return }
        let destination = recordingDirectory(for: recordingID)
            .appendingPathComponent("Capture Sources", isDirectory: true)
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for artifact in result.sourceArtifacts {
            guard fileManager.fileExists(atPath: artifact.fileURL.path) else { continue }
            let target = destination.appendingPathComponent(artifact.source.filename)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: artifact.fileURL, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }

        if let diagnosticsURL = result.diagnosticsURL,
           fileManager.fileExists(atPath: diagnosticsURL.path) {
            let target = destination.appendingPathComponent("capture-diagnostics.json")
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: diagnosticsURL, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    func workingDirectory(for recordingID: UUID) throws -> URL {
        let directory = recordingDirectory(for: recordingID).appendingPathComponent("Processing", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func clearWorkingDirectory(for recordingID: UUID) throws {
        let directory = recordingDirectory(for: recordingID).appendingPathComponent("Processing", isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func moveRecordingToTrash(recordingID: UUID) throws {
        let directory = recordingDirectory(for: recordingID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: directory, resultingItemURL: &resultingURL)
    }
}
