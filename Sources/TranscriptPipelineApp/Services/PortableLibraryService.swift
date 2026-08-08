import Foundation
import SwiftData

enum PortableLibraryError: LocalizedError {
    case invalidPackage
    case unsupportedVersion(Int)
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "This is not a valid Transcript Pipeline package."
        case .unsupportedVersion(let version): "This package uses unsupported archive version \(version)."
        case .missingAudio: "The package does not contain its recording audio."
        }
    }
}

struct PortableAnalysisRevision: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let templateID: String
    let providerID: String
    let modelID: String
    let document: AnalysisDocument
    let usage: TokenUsage
    let isStale: Bool
}

struct PortableChatMessage: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let role: ChatRole
    let content: String
    let citations: [EvidenceCitation]
    let providerID: String
    let modelID: String
    let usage: TokenUsage
}

struct PortableRecordingManifest: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let originalID: UUID
    let title: String
    let importedAt: Date
    let updatedAt: Date
    let durationSeconds: Double
    let sourceFormat: String
    let languageHint: LanguageHint
    let providerID: String
    let transcriptionModel: String
    let insightModel: String
    let selectedTemplateID: String
    let authorizationConfirmed: Bool
    let folderName: String
    let tags: [String]
    let isFavorite: Bool
    let speakers: [PortableSpeaker]
    let transcript: [TranscriptSegmentValue]
    let analyses: [PortableAnalysisRevision]
    let chatMessages: [PortableChatMessage]
    let usage: [UsageEntry]
    let audioFilename: String
}

struct PortableSpeaker: Codable, Sendable {
    let providerLabel: String
    let displayName: String
    let colorIndex: Int
}

@MainActor
enum PortableLibraryService {
    static let manifestFilename = "manifest.json"

    static func exportPackage(recording: RecordingRecord) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineExports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeTitle = safeFilename(recording.title)
        let package = root.appendingPathComponent("\(safeTitle).\(AppConfiguration.archiveExtension)", isDirectory: true)
        if FileManager.default.fileExists(atPath: package.path) {
            try FileManager.default.removeItem(at: package)
        }
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let audioFilename = "audio.\(recording.sourceFormat.lowercased())"
        let destinationAudio = package.appendingPathComponent(audioFilename)
        guard FileManager.default.fileExists(atPath: recording.audioURL.path) else {
            throw PortableLibraryError.missingAudio
        }
        try FileManager.default.copyItem(at: recording.audioURL, to: destinationAudio)

        let manifest = manifest(for: recording, audioFilename: audioFilename)
        let data = try JSONCoding.encoder.encode(manifest)
        let manifestURL = package.appendingPathComponent(manifestFilename)
        try data.write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        return package
    }

    static func exportLibrary(recordings: [RecordingRecord]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transcript-Pipeline-Backup-\(formatter.string(from: Date()))", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for recording in recordings {
            let package = try exportPackage(recording: recording)
            var target = destination.appendingPathComponent(package.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) {
                target = destination.appendingPathComponent(
                    "\(package.deletingPathExtension().lastPathComponent)-\(recording.id.uuidString.prefix(8)).\(AppConfiguration.archiveExtension)",
                    isDirectory: true
                )
            }
            try FileManager.default.moveItem(at: package, to: target)
        }
        return destination
    }

    static func importPackage(
        from packageURL: URL,
        library: ManagedLibrary,
        modelContext: ModelContext
    ) async throws -> RecordingRecord {
        let hasAccess = packageURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { packageURL.stopAccessingSecurityScopedResource() } }

        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONCoding.decoder.decode(PortableRecordingManifest.self, from: data) else {
            throw PortableLibraryError.invalidPackage
        }
        guard manifest.schemaVersion == AppConfiguration.archiveSchemaVersion else {
            throw PortableLibraryError.unsupportedVersion(manifest.schemaVersion)
        }
        let audioURL = packageURL.appendingPathComponent(manifest.audioFilename)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw PortableLibraryError.missingAudio
        }

        let id = UUID()
        do {
            let imported = try await library.importFile(from: audioURL, recordingID: id)
            let recording = RecordingRecord(
                id: id,
                title: manifest.title,
                importedAt: manifest.importedAt,
                durationSeconds: imported.durationSeconds,
                localAudioPath: imported.managedURL.path,
                sourceFormat: imported.sourceFormat,
                languageHint: manifest.languageHint,
                authorizationConfirmed: manifest.authorizationConfirmed
            )
            recording.updatedAt = manifest.updatedAt
            recording.providerID = manifest.providerID
            recording.transcriptionModel = manifest.transcriptionModel
            recording.insightModel = manifest.insightModel
            recording.selectedTemplateID = manifest.selectedTemplateID
            recording.folderName = manifest.folderName
            recording.tags = manifest.tags
            recording.isFavorite = manifest.isFavorite
            recording.usageEntries = manifest.usage
            recording.processingStage = manifest.transcript.isEmpty ? .imported : .complete
            recording.processingProgress = manifest.transcript.isEmpty ? 0 : 1
            recording.segments = manifest.transcript.map(TranscriptSegmentRecord.init)
            recording.speakers = manifest.speakers.map {
                SpeakerRecord(providerLabel: $0.providerLabel, displayName: $0.displayName, colorIndex: $0.colorIndex)
            }
            recording.analyses = try manifest.analyses.map {
                try AnalysisRevisionRecord(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    templateID: $0.templateID,
                    providerID: $0.providerID,
                    modelID: $0.modelID,
                    document: $0.document,
                    usage: $0.usage,
                    isStale: $0.isStale
                )
            }
            recording.chatMessages = manifest.chatMessages.map {
                ChatMessageRecord(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    role: $0.role,
                    content: $0.content,
                    citations: $0.citations,
                    providerID: $0.providerID,
                    modelID: $0.modelID,
                    usage: $0.usage
                )
            }
            modelContext.insert(recording)
            try modelContext.save()
            return recording
        } catch {
            try? library.moveRecordingToTrash(recordingID: id)
            throw error
        }
    }

    static func packageURLs(in folder: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == AppConfiguration.archiveExtension }
    }

    private static func manifest(for recording: RecordingRecord, audioFilename: String) -> PortableRecordingManifest {
        PortableRecordingManifest(
            schemaVersion: AppConfiguration.archiveSchemaVersion,
            exportedAt: Date(),
            originalID: recording.id,
            title: recording.title,
            importedAt: recording.importedAt,
            updatedAt: recording.updatedAt,
            durationSeconds: recording.durationSeconds,
            sourceFormat: recording.sourceFormat,
            languageHint: recording.languageHint,
            providerID: recording.providerID,
            transcriptionModel: recording.transcriptionModel,
            insightModel: recording.insightModel,
            selectedTemplateID: recording.selectedTemplateID,
            authorizationConfirmed: recording.authorizationConfirmed,
            folderName: recording.folderName,
            tags: recording.tags,
            isFavorite: recording.isFavorite,
            speakers: recording.speakers.map {
                PortableSpeaker(providerLabel: $0.providerLabel, displayName: $0.displayName, colorIndex: $0.colorIndex)
            },
            transcript: recording.sortedSegments.map(\.value),
            analyses: recording.sortedAnalyses.compactMap { revision in
                guard let document = revision.document else { return nil }
                return PortableAnalysisRevision(
                    id: revision.id,
                    createdAt: revision.createdAt,
                    templateID: revision.templateID,
                    providerID: revision.providerID,
                    modelID: revision.modelID,
                    document: document,
                    usage: revision.usage,
                    isStale: revision.isStale
                )
            },
            chatMessages: recording.sortedChatMessages.map {
                PortableChatMessage(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    role: $0.role,
                    content: $0.content,
                    citations: $0.citations,
                    providerID: $0.providerID,
                    modelID: $0.modelID,
                    usage: $0.usage
                )
            },
            usage: recording.usageEntries,
            audioFilename: audioFilename
        )
    }

    private static func safeFilename(_ title: String) -> String {
        let safe = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .prefix(80)
        return safe.isEmpty ? "Recording" : String(safe)
    }
}
