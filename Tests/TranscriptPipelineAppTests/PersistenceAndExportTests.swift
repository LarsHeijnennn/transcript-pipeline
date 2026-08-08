import AVFoundation
import Foundation
import PDFKit
import SwiftData
import XCTest
@testable import TranscriptPipelineApp

@MainActor
final class PersistenceAndExportTests: XCTestCase {
    func testSwiftDataRoundTripAndExportsContainGroundedContent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("example.m4a")
        let recording = RecordingRecord(
            title: "Planning session",
            durationSeconds: 90,
            localAudioPath: sourceURL.path,
            sourceFormat: "m4a",
            authorizationConfirmed: true
        )
        let segment = TranscriptSegmentValue(
            speakerID: "speaker-1",
            startSeconds: 10,
            endSeconds: 15,
            text: "We approved the pilot."
        )
        recording.segments = [TranscriptSegmentRecord(value: segment)]
        recording.speakers = [SpeakerRecord(providerLabel: "speaker-1", displayName: "Alex", colorIndex: 0)]
        let citation = EvidenceCitation(segmentID: segment.id, startSeconds: 10, endSeconds: 15)
        let document = AnalysisDocument(
            title: "Pilot planning",
            overview: "The team approved a pilot.",
            sections: [AnalysisSection(heading: "Key points", items: [CitedText(text: "Pilot approved", citations: [citation])])],
            decisions: [CitedText(text: "Run the pilot", citations: [citation])],
            actionItems: [ActionItem(task: "Prepare pilot", owner: "Alex", citations: [citation])],
            openQuestions: []
        )
        recording.analyses = [try AnalysisRevisionRecord(
            templateID: "general-meeting",
            providerID: "openai",
            modelID: "gpt-5.6-luna",
            document: document,
            usage: TokenUsage(inputTokens: 100, outputTokens: 50, cachedInputTokens: 0)
        )]
        context.insert(recording)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<RecordingRecord>()).first)
        XCTAssertEqual(fetched.sortedSegments.first?.effectiveText, "We approved the pilot.")
        let markdown = ExportService.markdown(for: fetched)
        XCTAssertTrue(markdown.contains("## Decisions"))
        XCTAssertTrue(markdown.contains("[00:10]"))
        XCTAssertTrue(markdown.contains("Alex"))

        let jsonURL = try ExportService.export(recording: fetched, format: .json)
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        XCTAssertTrue(json.contains("Planning session"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))

        let pdfURL = try ExportService.export(recording: fetched, format: .pdf)
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: pdfURL)).pageCount, 0)
    }

    func testManagedLibraryCopiesSupportedAudioWithoutChangingSource() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source.wav")
        try makeWaveFile(at: source, seconds: 1)
        let originalData = try Data(contentsOf: source)

        let library = try ManagedLibrary(rootURL: temporary.appendingPathComponent("Library"))
        let imported = try await library.importFile(from: source, recordingID: UUID())
        XCTAssertEqual(imported.sourceFormat, "wav")
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        XCTAssertEqual(try Data(contentsOf: imported.managedURL), originalData)
        XCTAssertEqual(imported.durationSeconds, 1, accuracy: 0.1)
    }

    func testSubtitleAndDOCXExportsAreUsable() throws {
        let recording = RecordingRecord(
            title: "Caption test",
            durationSeconds: 5,
            localAudioPath: "/tmp/caption.m4a",
            sourceFormat: "m4a",
            authorizationConfirmed: true
        )
        recording.segments = [TranscriptSegmentRecord(value: TranscriptSegmentValue(
            speakerID: "speaker-1",
            startSeconds: 1.25,
            endSeconds: 3.5,
            text: "Hello & welcome."
        ))]
        recording.speakers = [SpeakerRecord(providerLabel: "speaker-1", displayName: "Alex", colorIndex: 0)]
        let srt = ExportService.subtitles(for: recording, webVTT: false)
        XCTAssertTrue(srt.contains("00:00:01,250 --> 00:00:03,500"))
        XCTAssertTrue(srt.contains("Alex: Hello & welcome."))
        let vtt = ExportService.subtitles(for: recording, webVTT: true)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:01.250"))
        let actionDocument = AnalysisDocument(
            title: "Tasks", overview: "", sections: [], decisions: [],
            actionItems: [ActionItem(task: "Prepare follow-up", owner: "Alex", dueDate: "2026-08-20")],
            openQuestions: []
        )
        recording.analyses = [try AnalysisRevisionRecord(
            templateID: "general-meeting", providerID: "openai", modelID: "test",
            document: actionDocument, usage: .zero
        )]
        let calendar = ExportService.calendarItems(for: recording)
        XCTAssertTrue(calendar.contains("BEGIN:VTODO"))
        XCTAssertTrue(calendar.contains("DUE;VALUE=DATE:20260820"))
        let docx = try ExportService.export(recording: recording, format: .docx)
        let data = try Data(contentsOf: docx)
        XCTAssertTrue(data.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertGreaterThan(data.count, 500)
    }

    func testPortablePackageRoundTripPreservesWorkingData() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("source.wav")
        try makeWaveFile(at: audio, seconds: 1)
        let recording = RecordingRecord(
            title: "Portable session",
            durationSeconds: 1,
            localAudioPath: audio.path,
            sourceFormat: "wav",
            authorizationConfirmed: true
        )
        recording.folderName = "Research"
        recording.tags = ["Pilot"]
        recording.isFavorite = true
        recording.segments = [TranscriptSegmentRecord(value: TranscriptSegmentValue(
            speakerID: "speaker-1", startSeconds: 0, endSeconds: 1, text: "Portable transcript"
        ))]
        let package = try PortableLibraryService.exportPackage(recording: recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("manifest.json").path))

        let library = try ManagedLibrary(rootURL: temporary.appendingPathComponent("RestoredLibrary"))
        let container = try makeContainer()
        let restored = try await PortableLibraryService.importPackage(
            from: package,
            library: library,
            modelContext: container.mainContext
        )
        XCTAssertEqual(restored.title, "Portable session")
        XCTAssertEqual(restored.folderName, "Research")
        XCTAssertEqual(restored.tags, ["Pilot"])
        XCTAssertTrue(restored.isFavorite)
        XCTAssertEqual(restored.sortedSegments.first?.effectiveText, "Portable transcript")
        XCTAssertNotEqual(restored.id, recording.id)
    }

    func testLiveRecordingModesExposeExpectedPermissionBoundary() {
        XCTAssertFalse(LiveRecordingMode.microphone.requiresScreenCapture)
        XCTAssertTrue(LiveRecordingMode.macAudioAndMicrophone.requiresScreenCapture)
        XCTAssertTrue(LiveRecordingMode.macAudioAndMicrophone.detail.contains("Teams"))
    }

    func testAudioTrackMergerProducesReadableAAC() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineMixerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let first = temporary.appendingPathComponent("first.wav")
        let second = temporary.appendingPathComponent("second.wav")
        let output = temporary.appendingPathComponent("mixed.m4a")
        try makeWaveFile(at: first, seconds: 1)
        try makeWaveFile(at: second, seconds: 1)

        try await AudioTrackMerger.merge(audioURLs: [first, second], outputURL: output)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(duration, 1, accuracy: 0.15)
        XCTAssertEqual(audioTrackCount, 1)
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 1_000)
    }

    func testRecordedAudioValidatorRejectsMissingTrackAndAcceptsReadableAudio() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineTrackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let missing = temporary.appendingPathComponent("missing.m4a")
        do {
            try await RecordedAudioValidator.validateTrack(at: missing, source: "Test source")
            XCTFail("A missing required track must not be accepted")
        } catch let error as LiveRecordingError {
            XCTAssertTrue(error.localizedDescription.contains("Test source"))
        }

        let readable = temporary.appendingPathComponent("readable.wav")
        try makeWaveFile(at: readable, seconds: 1)
        try await RecordedAudioValidator.validateTrack(at: readable, source: "Test source")
    }

    func testMultipartUploadBodyStreamsToPrivateTemporaryFile() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineMultipartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let audio = temporary.appendingPathComponent("part.m4a")
        let body = temporary.appendingPathComponent("body.tmp")
        let bytes = Data(repeating: 0x5A, count: 2 * 1_048_576)
        try bytes.write(to: audio)

        let multipart = try MultipartFormFile(boundary: "Boundary-Test", outputURL: body)
        try multipart.addField(name: "model", value: "test-model")
        try multipart.addFile(name: "file", filename: "part.m4a", mimeType: "audio/m4a", fileURL: audio)
        try multipart.finalize()

        let bodyData = try Data(contentsOf: body)
        XCTAssertTrue(bodyData.starts(with: Data("--Boundary-Test\r\n".utf8)))
        XCTAssertNotNil(bodyData.range(of: Data("test-model".utf8)))
        XCTAssertNotNil(bodyData.range(of: Data(bytes.prefix(256))))
        XCTAssertNotNil(bodyData.range(of: Data("--Boundary-Test--\r\n".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: body.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: RecordingRecord.self,
            TranscriptSegmentRecord.self,
            SpeakerRecord.self,
            AnalysisRevisionRecord.self,
            ChatMessageRecord.self,
            CustomTemplateRecord.self,
            configurations: configuration
        )
    }

    private func makeWaveFile(at url: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 16_000) * 0.1)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
