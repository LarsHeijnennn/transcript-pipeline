import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum AudioPreparationError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case writerFailed(String)
    case outputTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "No readable audio track was found."
        case .readerFailed(let detail):
            "Audio preparation failed while reading: \(detail)"
        case .writerFailed(let detail):
            "Audio preparation failed while writing: \(detail)"
        case .outputTooLarge(let bytes):
            "A prepared audio part still exceeds 24 MB (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        }
    }
}

struct SilenceSample: Equatable, Sendable {
    let second: Double
    let energy: Double
}

actor AudioPreparationService {
    private let targetPartDuration: TimeInterval = 40 * 60
    private let searchWindow: TimeInterval = 30
    private let overlap: TimeInterval = 1
    private let fileManager = FileManager.default

    func prepare(
        sourceURL: URL,
        duration: TimeInterval,
        workingDirectory: URL
    ) async throws -> [PreparedAudioPart] {
        let samples = (try? await silenceSamples(sourceURL: sourceURL, duration: duration)) ?? []
        let boundaries = Self.chooseBoundaries(
            duration: duration,
            targetPartDuration: targetPartDuration,
            searchWindow: searchWindow,
            samples: samples
        )
        let ranges = makeRanges(duration: duration, boundaries: boundaries)
        var parts: [PreparedAudioPart] = []

        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let outputURL = workingDirectory.appendingPathComponent(String(format: "part-%03d.m4a", index))
            do {
                try await encodeAAC(sourceURL: sourceURL, range: range.actualRange, outputURL: outputURL)
                let byteCount = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard byteCount <= AppConfiguration.maximumUploadBytes else {
                    throw AudioPreparationError.outputTooLarge(byteCount)
                }
                parts.append(
                    PreparedAudioPart(
                        fileURL: outputURL,
                        startSeconds: range.actualRange.lowerBound,
                        endSeconds: range.actualRange.upperBound,
                        nominalStartSeconds: range.nominalStart,
                        partIndex: index
                    )
                )
            } catch {
                // AVFoundation cannot decode every WebM variant. A small original remains valid for OpenAI.
                if ranges.count == 1 {
                    let byteCount = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    if byteCount <= AppConfiguration.maximumUploadBytes {
                        return [
                            PreparedAudioPart(
                                fileURL: sourceURL,
                                startSeconds: 0,
                                endSeconds: duration,
                                nominalStartSeconds: 0,
                                partIndex: 0
                            )
                        ]
                    }
                }
                throw error
            }
        }
        return parts
    }

    func makeSpeakerReference(
        sourceURL: URL,
        segment: TranscriptSegmentValue,
        name: String,
        workingDirectory: URL
    ) async throws -> KnownSpeakerReference {
        let duration = min(8, max(2, segment.endSeconds - segment.startSeconds))
        let start = max(0, segment.startSeconds)
        let output = workingDirectory.appendingPathComponent("reference-\(name).m4a")
        try await encodeAAC(sourceURL: sourceURL, range: start...(start + duration), outputURL: output)
        return KnownSpeakerReference(name: name, audioURL: output)
    }

    static func chooseBoundaries(
        duration: TimeInterval,
        targetPartDuration: TimeInterval,
        searchWindow: TimeInterval,
        samples: [SilenceSample]
    ) -> [TimeInterval] {
        guard duration > targetPartDuration else { return [] }
        var boundaries: [TimeInterval] = []
        var target = targetPartDuration
        while target < duration {
            let candidates = samples.filter { abs($0.second - target) <= searchWindow }
            let chosen = candidates.min { lhs, rhs in
                if lhs.energy == rhs.energy {
                    return abs(lhs.second - target) < abs(rhs.second - target)
                }
                return lhs.energy < rhs.energy
            }?.second ?? target
            if chosen > (boundaries.last ?? 0) + 60, duration - chosen > 60 {
                boundaries.append(chosen)
            }
            target += targetPartDuration
        }
        return boundaries
    }

    private func makeRanges(
        duration: TimeInterval,
        boundaries: [TimeInterval]
    ) -> [(nominalStart: TimeInterval, actualRange: ClosedRange<TimeInterval>)] {
        let points = [0] + boundaries + [duration]
        return (0..<(points.count - 1)).map { index in
            let nominalStart = points[index]
            let actualStart = index == 0 ? nominalStart : max(0, nominalStart - overlap)
            let actualEnd = index == points.count - 2 ? points[index + 1] : min(duration, points[index + 1] + overlap)
            return (nominalStart, actualStart...actualEnd)
        }
    }

    private func silenceSamples(sourceURL: URL, duration: TimeInterval) async throws -> [SilenceSample] {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioPreparationError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: Self.pcmSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioPreparationError.noAudioTrack }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioPreparationError.readerFailed(reader.error?.localizedDescription ?? "Unknown reader error")
        }

        let secondCount = max(1, Int(ceil(duration)) + 1)
        var energySums = Array(repeating: 0.0, count: secondCount)
        var sampleCounts = Array(repeating: 0, count: secondCount)

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let second = min(max(0, Int(time)), secondCount - 1)
            if let energy = Self.meanAbsoluteAmplitude(sampleBuffer) {
                energySums[second] += energy
                sampleCounts[second] += 1
            }
        }
        guard reader.status == .completed else {
            throw AudioPreparationError.readerFailed(reader.error?.localizedDescription ?? "Reader stopped unexpectedly")
        }

        return energySums.indices.compactMap { index in
            guard sampleCounts[index] > 0 else { return nil }
            return SilenceSample(second: Double(index), energy: energySums[index] / Double(sampleCounts[index]))
        }
    }

    private func encodeAAC(
        sourceURL: URL,
        range: ClosedRange<TimeInterval>,
        outputURL: URL
    ) async throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioPreparationError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 1_000),
            duration: CMTime(seconds: range.upperBound - range.lowerBound, preferredTimescale: 1_000)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioPreparationError.noAudioTrack }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw AudioPreparationError.writerFailed("AAC writer rejected the audio settings")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AudioPreparationError.writerFailed(writer.error?.localizedDescription ?? "Writer did not start")
        }
        writer.startSession(atSourceTime: reader.timeRange.start)
        guard reader.startReading() else {
            throw AudioPreparationError.readerFailed(reader.error?.localizedDescription ?? "Reader did not start")
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            if input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else { break }
                if !input.append(sample) {
                    reader.cancelReading()
                    throw AudioPreparationError.writerFailed(writer.error?.localizedDescription ?? "Could not append audio")
                }
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioPreparationError.writerFailed(writer.error?.localizedDescription ?? "Writer stopped unexpectedly")
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }

    private static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
    }

    private static func meanAbsoluteAmplitude(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer, length >= 2 else { return nil }
        let sampleCount = length / MemoryLayout<Int16>.size
        let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
        var sum = 0.0
        let strideSize = max(1, sampleCount / 2_000)
        var inspected = 0
        var index = 0
        while index < sampleCount {
            sum += abs(Double(Int16(littleEndian: samples[index])))
            inspected += 1
            index += strideSize
        }
        return inspected > 0 ? sum / Double(inspected) : nil
    }
}
