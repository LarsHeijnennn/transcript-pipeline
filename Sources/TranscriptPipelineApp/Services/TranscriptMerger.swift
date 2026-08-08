import Foundation

struct PartTranscription: Sendable {
    let part: PreparedAudioPart
    let result: TranscriptionResult
}

struct MergedTranscript: Sendable {
    let segments: [TranscriptSegmentValue]
    let speakerDisplayNames: [String: String]
    let usage: TokenUsage
}

enum TranscriptMerger {
    static func merge(_ parts: [PartTranscription]) -> MergedTranscript {
        var merged: [TranscriptSegmentValue] = []
        var displayNames: [String: String] = [:]
        var firstPartAliases: [String: String] = [:]
        var nextSpeakerNumber = 1
        var totalUsage = TokenUsage.zero

        for item in parts.sorted(by: { $0.part.partIndex < $1.part.partIndex }) {
            totalUsage = totalUsage + item.result.usage
            for segment in item.result.segments {
                let rawLabel = segment.speakerID
                let canonical: String
                if item.part.partIndex == 0 {
                    if let existing = firstPartAliases[rawLabel] {
                        canonical = existing
                    } else {
                        canonical = "speaker-\(nextSpeakerNumber)"
                        firstPartAliases[rawLabel] = canonical
                        displayNames[canonical] = "Speaker \(nextSpeakerNumber)"
                        nextSpeakerNumber += 1
                    }
                } else if displayNames[rawLabel] != nil {
                    // Known-speaker references ask OpenAI to return canonical names.
                    canonical = rawLabel
                } else {
                    let chunkLabel = "chunk-\(item.part.partIndex)-\(rawLabel)"
                    if let known = firstPartAliases[chunkLabel] {
                        canonical = known
                    } else {
                        canonical = "speaker-\(nextSpeakerNumber)"
                        firstPartAliases[chunkLabel] = canonical
                        displayNames[canonical] = "Speaker \(nextSpeakerNumber)"
                        nextSpeakerNumber += 1
                    }
                }

                let absolute = TranscriptSegmentValue(
                    speakerID: canonical,
                    startSeconds: item.part.startSeconds + segment.startSeconds,
                    endSeconds: item.part.startSeconds + segment.endSeconds,
                    text: segment.text
                )
                if isOverlapDuplicate(absolute, existing: merged, nominalStart: item.part.nominalStartSeconds) {
                    continue
                }
                merged.append(absolute)
            }
        }

        merged.sort { lhs, rhs in
            if lhs.startSeconds == rhs.startSeconds { return lhs.endSeconds < rhs.endSeconds }
            return lhs.startSeconds < rhs.startSeconds
        }
        return MergedTranscript(segments: merged, speakerDisplayNames: displayNames, usage: totalUsage)
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func isOverlapDuplicate(
        _ candidate: TranscriptSegmentValue,
        existing: [TranscriptSegmentValue],
        nominalStart: TimeInterval
    ) -> Bool {
        guard nominalStart > 0, candidate.startSeconds <= nominalStart + 3 else { return false }
        return existing.suffix(8).contains { previous in
            let timesOverlap = previous.endSeconds >= candidate.startSeconds - 2
                && previous.startSeconds <= candidate.endSeconds + 2
            return timesOverlap && similarity(previous.text, candidate.text) >= 0.72
        }
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 }
        )
    }
}
