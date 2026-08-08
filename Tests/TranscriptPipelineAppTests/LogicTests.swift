import Foundation
import XCTest
@testable import TranscriptPipelineApp

final class LogicTests: XCTestCase {
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
