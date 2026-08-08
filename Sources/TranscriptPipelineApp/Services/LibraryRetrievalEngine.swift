import Foundation

struct LibraryRetrievalDocument: Sendable {
    let recordingID: UUID
    let recordingTitle: String
    let segments: [LibraryRetrievalSegment]
}

struct LibraryRetrievalSegment: Sendable {
    let value: TranscriptSegmentValue
    let speakerName: String
}

enum LibraryRetrievalEngine {
    @MainActor
    static func evidence(
        for question: String,
        recordings: [RecordingRecord],
        limit: Int = 30
    ) -> [LibraryEvidence] {
        evidence(for: question, documents: documents(from: recordings), limit: limit)
    }

    @MainActor
    static func documents(from recordings: [RecordingRecord]) -> [LibraryRetrievalDocument] {
        recordings.compactMap { recording in
            guard !recording.segments.isEmpty else { return nil }
            let speakers = Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.providerLabel, $0.displayName) })
            return LibraryRetrievalDocument(
                recordingID: recording.id,
                recordingTitle: recording.title,
                segments: recording.sortedSegments.compactMap { segment in
                    let value = segment.value
                    guard !value.text.isEmpty else { return nil }
                    return LibraryRetrievalSegment(
                        value: value,
                        speakerName: speakers[value.speakerID] ?? value.speakerID
                    )
                }
            )
        }
    }

    nonisolated static func evidence(
        for question: String,
        documents: [LibraryRetrievalDocument],
        limit: Int = 30
    ) -> [LibraryEvidence] {
        let terms = meaningfulTerms(question)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let normalizedQuestion = normalized(question)
        var results: [LibraryEvidence] = []
        for document in documents {
            guard !Task.isCancelled else { return [] }
            let normalizedTitle = normalized(document.recordingTitle)
            let titleBonus = terms.contains(where: normalizedTitle.contains) ? 0.5 : 0
            for segment in document.segments {
                let normalizedText = normalized(segment.value.text)
                let matches = terms.reduce(0) { $0 + (normalizedText.contains($1) ? 1 : 0) }
                guard matches > 0 else { continue }
                let exactBonus = normalizedText.contains(normalizedQuestion) ? 3.0 : 0
                let density = Double(matches) / Double(terms.count)
                results.append(LibraryEvidence(
                    recordingID: document.recordingID,
                    recordingTitle: document.recordingTitle,
                    segment: segment.value,
                    speakerName: segment.speakerName,
                    score: density * 10 + exactBonus + titleBonus
                ))
            }
        }
        return Array(results.sorted {
            if $0.score == $1.score { return $0.segment.startSeconds < $1.segment.startSeconds }
            return $0.score > $1.score
        }.prefix(limit))
    }

    private nonisolated static func meaningfulTerms(_ value: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "were", "what", "when", "where", "which", "who", "why", "with",
            "de", "een", "en", "er", "het", "hoe", "ik", "in", "is", "met", "naar", "of", "om", "op", "te", "van", "voor", "waar", "wat", "wie", "zijn"
        ]
        return Array(Set(normalized(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }))
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
