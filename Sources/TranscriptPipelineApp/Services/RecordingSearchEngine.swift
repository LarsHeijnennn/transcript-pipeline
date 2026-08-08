import Combine
import Foundation

struct RecordingSearchDocument: Sendable {
    let id: UUID
    let title: String
    let folder: String
    let tags: [String]
    let isFavorite: Bool
    let processingStage: ProcessingStage
    let hasTranscript: Bool
    let hasStaleAnalysis: Bool
    let entries: [RecordingSearchEntry]
}

struct RecordingSearchEntry: Sendable {
    let id: String
    let kind: SearchMatchKind
    let text: String
    let normalizedText: String
    let timestamp: TimeInterval?
    let score: Int
}

struct LibrarySearchResult: Sendable {
    let matches: [RecordingSearchMatch]
    let recordingIDs: Set<UUID>
    let bestMatchByRecordingID: [UUID: RecordingSearchMatch]
    let filterCounts: [LibrarySmartFilter: Int]
    let folders: [String]
    let tags: [String]

    static let empty = LibrarySearchResult(
        matches: [],
        recordingIDs: [],
        bestMatchByRecordingID: [:],
        filterCounts: [:],
        folders: [],
        tags: []
    )
}

@MainActor
final class LibrarySearchController: ObservableObject {
    @Published private(set) var result = LibrarySearchResult.empty
    @Published private(set) var isReady = false

    private struct CacheKey: Equatable {
        let updatedAt: Date
        let title: String
        let folder: String
        let tagsData: Data
        let isFavorite: Bool
        let processingStageRaw: String
        let segmentCount: Int
        let speakerCount: Int
        let analysisCount: Int
    }

    private struct CachedDocument {
        let key: CacheKey
        let document: RecordingSearchDocument
    }

    private var cache: [UUID: CachedDocument] = [:]
    private var generation = 0

    func refresh(
        recordings: [RecordingRecord],
        query: String,
        filter: LibrarySmartFilter,
        folder: String?,
        tag: String?
    ) async {
        generation += 1
        let currentGeneration = generation
        let documents = cachedDocuments(for: recordings)

        if !query.trimmed.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(110))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, currentGeneration == generation else { return }

        let worker = Task.detached(priority: .userInitiated) {
            RecordingSearchEngine.result(
                documents: documents,
                query: query,
                filter: filter,
                folder: folder,
                tag: tag
            )
        }
        let next = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled, currentGeneration == generation else { return }
        result = next
        isReady = true
    }

    private func cachedDocuments(for recordings: [RecordingRecord]) -> [RecordingSearchDocument] {
        let liveIDs = Set(recordings.map(\.id))
        cache = cache.filter { liveIDs.contains($0.key) }

        return recordings.map { recording in
            let key = CacheKey(
                updatedAt: recording.updatedAt,
                title: recording.title,
                folder: recording.folderName,
                tagsData: recording.tagsData,
                isFavorite: recording.isFavorite,
                processingStageRaw: recording.processingStageRaw,
                segmentCount: recording.segments.count,
                speakerCount: recording.speakers.count,
                analysisCount: recording.analyses.count
            )
            if let cached = cache[recording.id], cached.key == key {
                return cached.document
            }
            let document = RecordingSearchEngine.document(for: recording)
            cache[recording.id] = CachedDocument(key: key, document: document)
            return document
        }
    }
}

enum RecordingSearchEngine {
    @MainActor
    static func matches(
        recordings: [RecordingRecord],
        query: String,
        filter: LibrarySmartFilter = .all,
        folder: String? = nil,
        tag: String? = nil
    ) -> [RecordingSearchMatch] {
        matches(
            documents: recordings.map(document(for:)),
            query: query,
            filter: filter,
            folder: folder,
            tag: tag
        )
    }

    @MainActor
    static func matchingRecordingIDs(
        recordings: [RecordingRecord],
        query: String,
        filter: LibrarySmartFilter,
        folder: String? = nil,
        tag: String? = nil
    ) -> Set<UUID> {
        Set(matches(recordings: recordings, query: query, filter: filter, folder: folder, tag: tag).map(\.recordingID))
    }

    @MainActor
    static func document(for recording: RecordingRecord) -> RecordingSearchDocument {
        var entries: [RecordingSearchEntry] = []
        appendEntry(&entries, recordingID: recording.id, suffix: "title", kind: .title, text: recording.title, score: 100)
        appendEntry(&entries, recordingID: recording.id, suffix: "folder", kind: .folder, text: recording.folderName, score: 60)
        for (index, tag) in recording.tags.enumerated() {
            appendEntry(&entries, recordingID: recording.id, suffix: "tag-\(index)", kind: .tag, text: tag, score: 70)
        }
        for speaker in recording.speakers {
            appendEntry(&entries, recordingID: recording.id, suffix: "speaker-\(speaker.id.uuidString)", kind: .speaker, text: speaker.displayName, score: 55)
        }
        for segment in recording.sortedSegments where !segment.effectiveText.isEmpty {
            appendEntry(
                &entries,
                recordingID: recording.id,
                suffix: "segment-\(segment.id.uuidString)",
                kind: .transcript,
                text: segment.effectiveText,
                timestamp: segment.startSeconds,
                score: 80
            )
        }
        if let document = recording.currentAnalysis?.document {
            let noteTexts = [document.overview]
                + document.sections.flatMap { $0.items.map(\.text) }
                + document.decisions.map(\.text)
                + document.openQuestions.map(\.text)
            for (index, text) in noteTexts.enumerated() {
                appendEntry(&entries, recordingID: recording.id, suffix: "note-\(index)", kind: .notes, text: text, score: 65)
            }
            for item in document.actionItems {
                appendEntry(
                    &entries,
                    recordingID: recording.id,
                    suffix: "action-\(item.id.uuidString)",
                    kind: .actionItem,
                    text: item.task,
                    timestamp: item.citations.first?.startSeconds,
                    score: 75
                )
            }
        }
        return RecordingSearchDocument(
            id: recording.id,
            title: recording.title,
            folder: recording.folderName,
            tags: recording.tags,
            isFavorite: recording.isFavorite,
            processingStage: recording.processingStage,
            hasTranscript: !recording.segments.isEmpty,
            hasStaleAnalysis: recording.hasStaleAnalysis,
            entries: entries
        )
    }

    nonisolated static func result(
        documents: [RecordingSearchDocument],
        query: String,
        filter: LibrarySmartFilter,
        folder: String?,
        tag: String?
    ) -> LibrarySearchResult {
        let matches = matches(documents: documents, query: query, filter: filter, folder: folder, tag: tag)
        let ids = Set(matches.map(\.recordingID))
        var best: [UUID: RecordingSearchMatch] = [:]
        if !query.trimmed.isEmpty {
            for match in matches where best[match.recordingID] == nil {
                best[match.recordingID] = match
            }
        }
        let counts = Dictionary(uniqueKeysWithValues: LibrarySmartFilter.allCases.map { smartFilter in
            (smartFilter, documents.lazy.filter { matchesFilter($0, filter: smartFilter) }.count)
        })
        let folders = Array(Set(documents.map(\.folder).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let tags = Array(Set(documents.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return LibrarySearchResult(
            matches: query.trimmed.isEmpty ? [] : matches,
            recordingIDs: ids,
            bestMatchByRecordingID: best,
            filterCounts: counts,
            folders: folders,
            tags: tags
        )
    }

    nonisolated static func matches(
        documents: [RecordingSearchDocument],
        query: String,
        filter: LibrarySmartFilter = .all,
        folder: String? = nil,
        tag: String? = nil
    ) -> [RecordingSearchMatch] {
        let terms = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return documents
            .filter { document in
                matchesFilter(document, filter: filter)
                    && (folder == nil || document.folder == folder)
                    && (tag == nil || document.tags.contains(where: { $0.caseInsensitiveCompare(tag!) == .orderedSame }))
            }
            .flatMap { document -> [RecordingSearchMatch] in
                if terms.isEmpty {
                    return [RecordingSearchMatch(
                        id: "\(document.id.uuidString)-title",
                        recordingID: document.id,
                        kind: .title,
                        snippet: document.title,
                        timestamp: nil,
                        score: 1
                    )]
                }
                return document.entries.compactMap { entry in
                    guard terms.allSatisfy(entry.normalizedText.contains) else { return nil }
                    return RecordingSearchMatch(
                        id: entry.id,
                        recordingID: document.id,
                        kind: entry.kind,
                        snippet: snippet(entry.text, normalizedText: entry.normalizedText, terms: terms),
                        timestamp: entry.timestamp,
                        score: entry.score
                    )
                }
            }
            .sorted {
                if $0.score == $1.score { return $0.snippet.localizedCaseInsensitiveCompare($1.snippet) == .orderedAscending }
                return $0.score > $1.score
            }
    }

    private nonisolated static func matchesFilter(_ document: RecordingSearchDocument, filter: LibrarySmartFilter) -> Bool {
        switch filter {
        case .all: true
        case .favorites: document.isFavorite
        case .needsProcessing: !document.hasTranscript && document.processingStage != .failed
        case .staleNotes: document.hasStaleAnalysis
        case .failed: document.processingStage == .failed
        }
    }

    @MainActor
    private static func appendEntry(
        _ entries: inout [RecordingSearchEntry],
        recordingID: UUID,
        suffix: String,
        kind: SearchMatchKind,
        text: String,
        timestamp: TimeInterval? = nil,
        score: Int
    ) {
        guard !text.trimmed.isEmpty else { return }
        entries.append(RecordingSearchEntry(
            id: "\(recordingID.uuidString)-\(suffix)",
            kind: kind,
            text: text,
            normalizedText: normalized(text),
            timestamp: timestamp,
            score: score
        ))
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private nonisolated static func snippet(_ value: String, normalizedText: String, terms: [String]) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.count > 150 else { return collapsed }
        let lower = collapsed.count == value.count ? normalizedText : normalized(collapsed)
        let firstIndex = terms.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? lower.startIndex
        let offset = lower.distance(from: lower.startIndex, to: firstIndex)
        let startOffset = max(0, offset - 45)
        let endOffset = min(collapsed.count, startOffset + 150)
        let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let end = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
        return "\(startOffset > 0 ? "…" : "")\(collapsed[start..<end])\(endOffset < collapsed.count ? "…" : "")"
    }
}
