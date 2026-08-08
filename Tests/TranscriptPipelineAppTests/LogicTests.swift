import AVFoundation
import Foundation
import XCTest
@testable import TranscriptPipelineApp

final class LogicTests: XCTestCase {
    func testWaveformSamplingCreatesReusableBoundedCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipeline-waveform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames: AVAudioFrameCount = 44_100
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                channel[frame] = Float(sin(Double(frame) * 0.03) * (frame % 4_000 < 2_000 ? 0.8 : 0.2))
            }
            try file.write(from: buffer)
        }

        let first = await AudioWaveformService.samples(for: url, bucketCount: 64)
        let second = await AudioWaveformService.samples(for: url, bucketCount: 64)

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second, first)
        XCTAssertEqual(first.max() ?? 0, 1, accuracy: 0.000_1)
        let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("waveform-v2-64") }
        XCTAssertEqual(cacheFiles.count, 1)
    }

    @MainActor
    func testLargeLibrarySearchPerformance() {
        let recordings = (0..<120).map { recordingIndex in
            let recording = RecordingRecord(
                title: "Planning session \(recordingIndex)",
                durationSeconds: 3_600,
                localAudioPath: "/tmp/performance-\(recordingIndex).m4a",
                sourceFormat: "m4a",
                authorizationConfirmed: true
            )
            recording.segments = (0..<100).map { segmentIndex in
                let isNeedle = segmentIndex == 73 && recordingIndex == 91
                let routine = "Routine project discussion segment \(segmentIndex) for recording \(recordingIndex)."
                let text = isNeedle ? "The unique performance needle appears here." : routine
                return TranscriptSegmentRecord(value: TranscriptSegmentValue(
                    speakerID: "speaker-\(segmentIndex % 4)",
                    startSeconds: Double(segmentIndex * 30),
                    endSeconds: Double(segmentIndex * 30 + 20),
                    text: text
                ))
            }
            return recording
        }
        let documents = recordings.map(RecordingSearchEngine.document(for:))
        measure(metrics: [XCTClockMetric()]) {
            let matches = RecordingSearchEngine.matches(documents: documents, query: "unique performance needle")
            XCTAssertEqual(matches.count, 1)
        }
    }

    @MainActor
    func testLibrarySearchFindsTranscriptNotesTagsAndFolders() throws {
        let recording = RecordingRecord(
            title: "Weekly planning",
            durationSeconds: 120,
            localAudioPath: "/tmp/search.m4a",
            sourceFormat: "m4a",
            authorizationConfirmed: true
        )
        recording.folderName = "University"
        recording.tags = ["Ethics"]
        recording.segments = [TranscriptSegmentRecord(value: TranscriptSegmentValue(
            speakerID: "speaker-1",
            startSeconds: 42,
            endSeconds: 48,
            text: "The AFib pilot needs ethical review."
        ))]
        recording.speakers = [SpeakerRecord(providerLabel: "speaker-1", displayName: "Morgan", colorIndex: 0)]
        recording.analyses = [try AnalysisRevisionRecord(
            templateID: "general-meeting",
            providerID: "openai",
            modelID: "test",
            document: AnalysisDocument(
                title: "Planning",
                overview: "A clinical study was discussed.",
                sections: [], decisions: [],
                actionItems: [ActionItem(task: "Submit ethics form")],
                openQuestions: []
            ),
            usage: .zero
        )]

        XCTAssertEqual(RecordingSearchEngine.matches(recordings: [recording], query: "AFib").first?.timestamp, 42)
        XCTAssertEqual(RecordingSearchEngine.matches(recordings: [recording], query: "Morgan").first?.kind, .speaker)
        XCTAssertEqual(RecordingSearchEngine.matches(recordings: [recording], query: "ethics form").first?.kind, .actionItem)
        XCTAssertEqual(RecordingSearchEngine.matches(recordings: [recording], query: "University").first?.kind, .folder)
    }

    @MainActor
    func testLocalLibraryRetrievalRanksRelevantSegments() {
        let recording = RecordingRecord(
            title: "Launch review",
            durationSeconds: 90,
            localAudioPath: "/tmp/retrieval.m4a",
            sourceFormat: "m4a",
            authorizationConfirmed: true
        )
        recording.segments = [
            TranscriptSegmentRecord(value: TranscriptSegmentValue(speakerID: "A", startSeconds: 0, endSeconds: 4, text: "Lunch starts at noon.")),
            TranscriptSegmentRecord(value: TranscriptSegmentValue(speakerID: "A", startSeconds: 10, endSeconds: 18, text: "The launch decision requires legal approval."))
        ]
        let evidence = LibraryRetrievalEngine.evidence(for: "What was the launch decision?", recordings: [recording])
        XCTAssertEqual(evidence.first?.segment.startSeconds, 10)
        XCTAssertTrue(evidence.first?.segment.text.contains("legal approval") == true)
    }

    func testActionItemDecodesOlderRevisionWithoutCompletionField() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","task":"Prepare report","owner":"","dueDate":"","citations":[]}"#
        let item = try JSONDecoder().decode(ActionItem.self, from: Data(json.utf8))
        XCTAssertFalse(item.isCompleted)
    }
    func testSilenceAwareBoundariesPreferLowEnergyNearTargets() {
        let samples = [
            SilenceSample(second: 2_375, energy: 0.8),
            SilenceSample(second: 2_392, energy: 0.02),
            SilenceSample(second: 2_410, energy: 0.3),
            SilenceSample(second: 4_790, energy: 0.5),
            SilenceSample(second: 4_805, energy: 0.01)
        ]
        let boundaries = AudioPreparationService.chooseBoundaries(
            duration: 7_200,
            targetPartDuration: 2_400,
            searchWindow: 30,
            samples: samples
        )
        XCTAssertEqual(boundaries, [2_392, 4_805])
    }

    func testTranscriptMergerOffsetsAndDeduplicatesOverlap() {
        let first = PreparedAudioPart(
            fileURL: URL(fileURLWithPath: "/tmp/one.m4a"),
            startSeconds: 0,
            endSeconds: 2_401,
            nominalStartSeconds: 0,
            partIndex: 0
        )
        let second = PreparedAudioPart(
            fileURL: URL(fileURLWithPath: "/tmp/two.m4a"),
            startSeconds: 2_399,
            endSeconds: 4_801,
            nominalStartSeconds: 2_400,
            partIndex: 1
        )
        let duplicate = TranscriptSegmentValue(
            speakerID: "speaker-1",
            startSeconds: 0,
            endSeconds: 2,
            text: "Project Atlas is approved for launch."
        )
        let merged = TranscriptMerger.merge([
            PartTranscription(
                part: first,
                result: TranscriptionResult(
                    segments: [TranscriptSegmentValue(
                        speakerID: "A",
                        startSeconds: 2_399,
                        endSeconds: 2_401,
                        text: "Project Atlas is approved for launch."
                    )],
                    detectedLanguage: "en",
                    usage: TokenUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 0),
                    rawResponse: nil
                )
            ),
            PartTranscription(
                part: second,
                result: TranscriptionResult(
                    segments: [
                        duplicate,
                        TranscriptSegmentValue(
                            speakerID: "speaker-1",
                            startSeconds: 3,
                            endSeconds: 7,
                            text: "Morgan will prepare the launch plan."
                        )
                    ],
                    detectedLanguage: "en",
                    usage: TokenUsage(inputTokens: 120, outputTokens: 25, cachedInputTokens: 0),
                    rawResponse: nil
                )
            )
        ])

        XCTAssertEqual(merged.segments.count, 2)
        XCTAssertEqual(merged.segments[1].startSeconds, 2_402, accuracy: 0.001)
        XCTAssertEqual(merged.segments[1].speakerID, "speaker-1")
        XCTAssertEqual(merged.usage.inputTokens, 220)
    }

    func testSimilarityIgnoresPunctuationAndCase() {
        XCTAssertGreaterThan(
            TranscriptMerger.similarity("Hello, PROJECT Atlas!", "hello project atlas"),
            0.99
        )
    }

    func testResponsesBodyDisablesStorageAndUsesStrictSchema() throws {
        let body = try OpenAIProvider.responsesBody(
            model: "gpt-5.6-luna",
            instructions: "Ground every claim.",
            input: "Transcript",
            schemaName: "test_schema",
            schema: OpenAIProvider.chatSchema
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-luna")
        let text = try XCTUnwrap(json["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNil(json["api_key"])
    }

    func testCitationResolverDropsUnknownAndDuplicateIDs() {
        let segment = TranscriptSegmentValue(
            speakerID: "speaker-1",
            startSeconds: 12,
            endSeconds: 18,
            text: "A confirmed decision."
        )
        let citations = OpenAIProvider.resolveCitations(
            [segment.id.uuidString, UUID().uuidString, segment.id.uuidString],
            lookup: [segment.id.uuidString: segment]
        )
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].startSeconds, 12)
    }

    func testPricingEstimateUsesDatedCatalog() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cachedInputTokens: 0)
        XCTAssertEqual(PricingCatalog.estimate(model: "gpt-5.6-luna", usage: usage), Decimal(string: "1.40"))
        XCTAssertNil(PricingCatalog.estimate(model: "custom-model", usage: usage))
    }

    func testTranscriptTimelineBinarySearchHandlesEdgesAndLargeInputs() {
        XCTAssertNil(TranscriptTimelineSearch.activeIndex(startTimes: [5, 10, 20], at: 4.9))
        XCTAssertEqual(TranscriptTimelineSearch.activeIndex(startTimes: [5, 10, 20], at: 5), 0)
        XCTAssertEqual(TranscriptTimelineSearch.activeIndex(startTimes: [5, 10, 20], at: 19.9), 1)
        XCTAssertEqual(TranscriptTimelineSearch.activeIndex(startTimes: [5, 10, 20], at: 200), 2)

        let largeTimeline = (0..<100_000).map { Double($0) * 0.5 }
        for index in stride(from: 0, to: largeTimeline.count, by: 997) {
            XCTAssertEqual(
                TranscriptTimelineSearch.activeIndex(
                    startTimes: largeTimeline,
                    at: largeTimeline[index] + 0.49
                ),
                index
            )
        }
    }
}
