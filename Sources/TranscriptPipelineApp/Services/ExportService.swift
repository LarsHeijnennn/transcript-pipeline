import AppKit
import Foundation
import PDFKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case json
    case pdf
    case docx
    case srt
    case vtt
    case calendar
    case package

    var id: String { rawValue }
    var title: String {
        switch self {
        case .package: "Complete recording package"
        case .calendar: "Calendar / tasks (ICS)"
        default: rawValue.uppercased()
        }
    }
    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .package: AppConfiguration.archiveExtension
        case .calendar: "ics"
        default: rawValue
        }
    }
}

struct RecordingExport: Codable {
    let id: UUID
    let title: String
    let importedAt: Date
    let durationSeconds: Double
    let provider: String
    let transcriptionModel: String
    let insightModel: String
    let folder: String
    let tags: [String]
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
            folder: recording.folderName,
            tags: recording.tags,
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
                return "- [\(item.isCompleted ? "x" : " ")] \(item.task)\(owner)\(due)\(citationSuffix(item.citations))"
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
        if format == .package {
            return try PortableLibraryService.exportPackage(recording: recording)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatWasSaidExports", isDirectory: true)
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
            try writePDF(markdown: markdown(for: recording), title: recording.title, to: url)
        case .docx:
            try writeDOCX(markdown: markdown(for: recording), to: url)
        case .srt:
            try Data(subtitles(for: recording, webVTT: false).utf8).write(to: url, options: .atomic)
        case .vtt:
            try Data(subtitles(for: recording, webVTT: true).utf8).write(to: url, options: .atomic)
        case .calendar:
            try Data(calendarItems(for: recording).utf8).write(to: url, options: .atomic)
        case .package:
            break
        }
        return url
    }

    private static func citationSuffix(_ citations: [EvidenceCitation]) -> String {
        guard !citations.isEmpty else { return "" }
        return " " + citations.map { "[\($0.startSeconds.clockString)]" }.joined(separator: " ")
    }

    static func notesOnly(for recording: RecordingRecord) -> String {
        guard let document = recording.currentAnalysis?.document else { return "" }
        var lines = [document.title, "", document.overview, ""]
        for section in document.sections {
            lines.append(section.heading)
            lines += section.items.map { "• \($0.text)" }
            lines.append("")
        }
        lines.append("Decisions")
        lines += document.decisions.map { "• \($0.text)" }
        lines += ["", "Action items"]
        lines += document.actionItems.map { "\($0.isCompleted ? "☑" : "☐") \($0.task)\($0.owner.isEmpty ? "" : " — \($0.owner)")" }
        lines += ["", "Open questions"]
        lines += document.openQuestions.map { "• \($0.text)" }
        return lines.joined(separator: "\n")
    }

    static func actionItemsOnly(for recording: RecordingRecord) -> String {
        recording.currentAnalysis?.document?.actionItems.map {
            "\($0.isCompleted ? "☑" : "☐") \($0.task)\($0.owner.isEmpty ? "" : " — \($0.owner)")\($0.dueDate.isEmpty ? "" : " (\($0.dueDate))")"
        }.joined(separator: "\n") ?? ""
    }

    static func calendarItems(for recording: RecordingRecord) -> String {
        guard let items = recording.currentAnalysis?.document?.actionItems, !items.isEmpty else { return "" }
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//What Was Said//Action Items//EN",
            "CALSCALE:GREGORIAN"
        ]
        let timestamp = icalTimestamp(Date())
        for item in items {
            lines += [
                "BEGIN:VTODO",
                "UID:\(item.id.uuidString)@what-was-said",
                "DTSTAMP:\(timestamp)",
                "SUMMARY:\(icalEscape(item.task))",
                "DESCRIPTION:\(icalEscape("From \(recording.title)\(item.owner.isEmpty ? "" : " · Owner: \(item.owner)")\(item.dueDate.isEmpty ? "" : " · Due: \(item.dueDate)")"))",
                "STATUS:\(item.isCompleted ? "COMPLETED" : "NEEDS-ACTION")"
            ]
            if item.isCompleted { lines.append("COMPLETED:\(timestamp)") }
            if let due = parseDueDate(item.dueDate) { lines.append("DUE;VALUE=DATE:\(icalDate(due))") }
            lines.append("END:VTODO")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func subtitles(for recording: RecordingRecord, webVTT: Bool) -> String {
        var lines: [String] = webVTT ? ["WEBVTT", ""] : []
        let speakers = Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.providerLabel, $0.displayName) })
        for (index, segment) in recording.sortedSegments.enumerated() where !segment.effectiveText.isEmpty {
            if !webVTT { lines.append(String(index + 1)) }
            lines.append("\(subtitleTime(segment.startSeconds, webVTT: webVTT)) --> \(subtitleTime(segment.endSeconds, webVTT: webVTT))")
            lines.append("\(speakers[segment.speakerID] ?? segment.speakerID): \(segment.effectiveText)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func subtitleTime(_ time: TimeInterval, webVTT: Bool) -> String {
        let milliseconds = max(0, Int((time * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let millis = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, webVTT ? "." : ",", millis)
    }

    private static func parseDueDate(_ value: String) -> Date? {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return nil }
        for format in ["yyyy-MM-dd", "dd-MM-yyyy", "d MMM yyyy", "MMM d, yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func icalTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func icalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func icalEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func writePDF(markdown: String, title: String, to url: URL) throws {
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
        textView.textStorage?.setAttributedString(styledText(from: markdown, documentTitle: title))
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

    private static func styledText(from markdown: String, documentTitle: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 5
        paragraph.lineSpacing = 2

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let font: NSFont
            let color: NSColor
            let value: String
            if trimmed.hasPrefix("# ") {
                font = .systemFont(ofSize: 24, weight: .bold)
                color = .labelColor
                value = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("## ") {
                font = .systemFont(ofSize: 16, weight: .semibold)
                color = .labelColor
                value = String(trimmed.dropFirst(3))
            } else if trimmed.hasPrefix("**[") {
                font = .systemFont(ofSize: 10)
                color = .secondaryLabelColor
                value = trimmed.replacingOccurrences(of: "**", with: "")
            } else {
                font = body
                color = .textColor
                value = trimmed.replacingOccurrences(of: "**", with: "")
            }
            output.append(NSAttributedString(
                string: value + "\n",
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            ))
        }
        return output
    }

    private static func writeDOCX(markdown: String, to url: URL) throws {
        let paragraphs = markdown.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let style: String
            let text: String
            if trimmed.hasPrefix("# ") {
                style = "<w:pPr><w:pStyle w:val=\"Title\"/></w:pPr>"
                text = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("## ") {
                style = "<w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr>"
                text = String(trimmed.dropFirst(3))
            } else {
                style = ""
                text = trimmed.replacingOccurrences(of: "**", with: "")
            }
            return "<w:p>\(style)<w:r><w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
        }.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        try StoredZipWriter.write(
            entries: [
                ("[Content_Types].xml", Data(contentTypes.utf8)),
                ("_rels/.rels", Data(relationships.utf8)),
                ("word/document.xml", Data(document.utf8))
            ],
            to: url
        )
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@MainActor
enum NativeSharing {
    static func share(_ url: URL) {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private enum StoredZipWriter {
    private struct CentralEntry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func write(entries: [(String, Data)], to url: URL) throws {
        var archive = Data()
        var central: [CentralEntry] = []
        for (nameString, contents) in entries {
            let name = Data(nameString.utf8)
            let crc = crc32(contents)
            let offset = UInt32(archive.count)
            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(crc)
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(name)
            archive.append(contents)
            central.append(CentralEntry(name: name, crc: crc, size: UInt32(contents.count), offset: offset))
        }
        let centralOffset = UInt32(archive.count)
        for entry in central {
            archive.appendLittleEndian(UInt32(0x02014b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(entry.crc)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(entry.offset)
            archive.append(entry.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(central.count))
        archive.appendLittleEndian(UInt16(central.count))
        archive.appendLittleEndian(centralSize)
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        try archive.write(to: url, options: .atomic)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
