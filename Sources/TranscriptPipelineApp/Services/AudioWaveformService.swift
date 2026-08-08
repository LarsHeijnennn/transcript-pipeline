import AVFoundation
import Foundation

enum AudioWaveformService {
    private static let cache = WaveformMemoryCache()

    static func samples(for url: URL, bucketCount: Int = 220) async -> [Double] {
        guard bucketCount > 0 else { return [] }
        let worker = Task.detached(priority: .utility) { () -> [Double] in
            guard let identity = sourceIdentity(for: url, bucketCount: bucketCount) else { return [] }
            if let cached = await cache.value(for: identity) { return cached }
            if let cached = loadDiskCache(for: identity, sourceURL: url) {
                await cache.insert(cached, for: identity)
                return cached
            }
            guard !Task.isCancelled else { return [] }
            let values = generateSamples(for: url, bucketCount: bucketCount)
            guard !Task.isCancelled, !values.isEmpty else { return values }
            saveDiskCache(values, identity: identity, sourceURL: url)
            await cache.insert(values, for: identity)
            return values
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func generateSamples(for url: URL, bucketCount: Int) -> [Double] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let totalFrames = max(1, Int64(file.length))
        let framesPerBucket = max(1, totalFrames / Int64(bucketCount))
        let sampledFrames = AVAudioFrameCount(min(4_096, max(512, framesPerBucket)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sampledFrames) else { return [] }
        var peaks = Array(repeating: 0.0, count: bucketCount)

        for bucket in 0..<bucketCount {
            guard !Task.isCancelled else { return [] }
            let bucketStart = Int64(bucket) * framesPerBucket
            let centeredStart = bucketStart + max(0, (framesPerBucket - Int64(sampledFrames)) / 2)
            let latestStart = max(0, totalFrames - Int64(sampledFrames))
            file.framePosition = AVAudioFramePosition(min(centeredStart, latestStart))
            do {
                try file.read(into: buffer, frameCount: sampledFrames)
            } catch {
                continue
            }
            guard let channels = buffer.floatChannelData else { continue }
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            let strideLength = max(1, frameLength / 1_024)
            var peak = 0.0
            for frame in stride(from: 0, to: frameLength, by: strideLength) {
                for channel in 0..<channelCount {
                    peak = max(peak, Double(abs(channels[channel][frame])))
                }
            }
            peaks[bucket] = peak
        }

        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks }
        return peaks.map { min(1, $0 / maximum) }
    }

    private static func sourceIdentity(for url: URL, bucketCount: Int) -> WaveformCacheIdentity? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return WaveformCacheIdentity(
            path: url.standardizedFileURL.path,
            fileSize: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            bucketCount: bucketCount
        )
    }

    private static func cacheURL(for sourceURL: URL, bucketCount: Int) -> URL {
        sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.lastPathComponent).waveform-v2-\(bucketCount).json")
    }

    private static func loadDiskCache(for identity: WaveformCacheIdentity, sourceURL: URL) -> [Double]? {
        let url = cacheURL(for: sourceURL, bucketCount: identity.bucketCount)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(WaveformDiskCache.self, from: data),
              payload.fileSize == identity.fileSize,
              payload.modifiedAt == identity.modifiedAt,
              payload.samples.count == identity.bucketCount else { return nil }
        return payload.samples
    }

    private static func saveDiskCache(_ samples: [Double], identity: WaveformCacheIdentity, sourceURL: URL) {
        let payload = WaveformDiskCache(fileSize: identity.fileSize, modifiedAt: identity.modifiedAt, samples: samples)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = cacheURL(for: sourceURL, bucketCount: identity.bucketCount)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A waveform is optional UI data; failure to cache must not affect playback.
        }
    }
}

private struct WaveformCacheIdentity: Hashable, Sendable {
    let path: String
    let fileSize: Int
    let modifiedAt: Date
    let bucketCount: Int
}

private struct WaveformDiskCache: Codable, Sendable {
    let fileSize: Int
    let modifiedAt: Date
    let samples: [Double]
}

private actor WaveformMemoryCache {
    private var values: [WaveformCacheIdentity: [Double]] = [:]

    func value(for identity: WaveformCacheIdentity) -> [Double]? {
        values[identity]
    }

    func insert(_ samples: [Double], for identity: WaveformCacheIdentity) {
        values[identity] = samples
        if values.count > 24, let first = values.keys.first {
            values.removeValue(forKey: first)
        }
    }
}
