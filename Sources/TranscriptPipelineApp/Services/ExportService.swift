import AppKit
import Foundation
import PDFKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case json
    case pdf

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .markdown ? "md" : rawValue }
}

struct RecordingExport: Codable {
    let id: UUID
    let title: String
    let importedAt: Date
    let durationSeconds: Double
    let provider: String
    let transcriptionModel: String
    let insightModel: String
    let speakers: [String: String]
    let transcript: [TranscriptSegmentValue]
    let latestAnalysis: AnalysisDocument?
    let usage: [UsageEntry]
}

@MainActor
enum ExportService {
    static func payload(for recording: RecordingRecord) -> RecordingExport {
        RecordingExport(
            id: recording.id,
            title: recording.title,
            importedAt: recording.importedAt,
            durationSeconds: recording.durationSeconds,
            provider: recording.providerID,
            transcriptionModel: recording.transcriptionModel,
            insightModel: recording.insightModel,
            speakers: Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.providerLabel, $0.displayName) }),
            transcript: recording.sortedSegments.map(\.value),
            latestAnalysis: recording.currentAnalysis?.document,
            usage: recording.usageEntries
        )
    }

    static func markdown(for recording: RecordingRecord) -> String {
        let export = payload(for: recording)
        var lines = [
            "# \(export.title)",
            "",
            "- Imported: \(export.importedAt.formatted(date: .long, time: .shortened))",
            "- Duration: \(export.durationSeconds.clockString)",
            "- Provider: \(export.provider)",
            "- Models: \(export.transcriptionModel), \(export.insightModel)",
            ""
        ]
        if let analysis = export.latestAnalysis {
            lines += ["## Overview", "", analysis.overview, ""]
            for section in analysis.sections {
                lines += ["## \(section.heading)", ""]
                lines += section.items.map { "- \($0.text)\(citationSuffix($0.citations))" }
                lines.append("")
            }
            lines += ["## Decisions", ""]
            lines += analysis.decisions.map { "- \($0.text)\(citationSuffix($0.citations))" }
            lines += ["", "## Action items", ""]
            lines += analysis.actionItems.map { item in
                let owner = item.owner.isEmpty ? "" : " — \(item.owner)"
                let due = item.dueDate.isEmpty ? "" : " (due \(item.dueDate))"
                return "- [ ] \(item.task)\(owner)\(due)\(citationSuffix(item.citations))"
            }
            lines += ["", "## Open questions", ""]
            lines += analysis.openQuestions.map { "- \($0.text)\(citationSuffix($0.citations))" }
            lines.append("")
        }
        lines += ["## Transcript", ""]
        for segment in export.transcript {
            let speaker = export.speakers[segment.speakerID] ?? segment.speakerID
            lines.append("**[\(segment.startSeconds.clockString)] \(speaker):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func export(recording: RecordingRecord, format: ExportFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptPipelineExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = recording.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .prefix(80)
        let url = directory.appendingPathComponent("\(safeTitle.isEmpty ? "Recording" : String(safeTitle)).\(format.fileExtension)")
        switch format {
        case .markdown:
            try Data(markdown(for: recording).utf8).write(to: url, options: .atomic)
        case .json:
            try JSONCoding.encoder.encode(payload(for: recording)).write(to: url, options: .atomic)
        case .pdf:
            try writePDF(markdown: markdown(for: recording), to: url)
        }
        return url
    }

    private static func citationSuffix(_ citations: [EvidenceCitation]) -> String {
        guard !citations.isEmpty else { return "" }
        return " " + citations.map { "[\($0.startSeconds.clockString)]" }.joined(separator: " ")
    }

    private static func writePDF(markdown: String, to url: URL) throws {
        let printInfo = NSPrintInfo.shared
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 50
        printInfo.bottomMargin = 50
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10_000))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = markdown
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = .textColor
        textView.sizeToFit()

        let pdfData = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(
            with: textView,
            inside: textView.bounds,
            to: pdfData,
            printInfo: printInfo
        )
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (pdfData as Data).write(to: url, options: .atomic)
        guard PDFDocument(url: url)?.pageCount ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

@MainActor
enum NativeSharing {
    static func share(_ url: URL) {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }
}
