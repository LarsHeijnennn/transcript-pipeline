import Foundation

struct LibraryDiagnosticsReport: Sendable {
    let missingAudioTitles: [String]
    let interruptedTitles: [String]
    let orphanDirectoryCount: Int
    let totalManagedBytes: Int64

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: totalManagedBytes, countStyle: .file)
        return "\(missingAudioTitles.count) missing audio · \(interruptedTitles.count) interrupted jobs · \(orphanDirectoryCount) unlinked folders · \(size) managed data"
    }
}

enum LibraryDiagnosticsService {
    @MainActor
    static func scan(recordings: [RecordingRecord], library: ManagedLibrary) -> LibraryDiagnosticsReport {
        let missing = recordings.filter { !FileManager.default.fileExists(atPath: $0.localAudioPath) }.map(\.title)
        let interrupted = recordings.filter { $0.processingStage.isActive }.map(\.title)
        let known = Set(recordings.map { $0.id.uuidString })
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: library.rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let orphanCount = directories.filter {
            $0.lastPathComponent != "LiveCaptures" && !known.contains($0.lastPathComponent)
        }.count
        let bytes = directorySize(library.rootURL)
        return LibraryDiagnosticsReport(
            missingAudioTitles: missing,
            interruptedTitles: interrupted,
            orphanDirectoryCount: orphanCount,
            totalManagedBytes: bytes
        )
    }

    @MainActor
    static func recoverInterruptedJobs(recordings: [RecordingRecord]) {
        for recording in recordings where recording.processingStage.isActive {
            recording.processingStage = .cancelled
            recording.processingDetail = "Interrupted when the app closed; completed parts are ready to resume"
            recording.lastError = "Processing was interrupted. Retry to continue from completed chunks."
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
