import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false

    let duration: TimeInterval
    private let player: AVPlayer
    private var timeObserver: Any?

    init(url: URL, duration: TimeInterval) {
        self.duration = duration
        self.player = AVPlayer(url: url)
        self.player.automaticallyWaitsToMinimizeStalling = false
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newTime = time.seconds.isFinite ? time.seconds : 0
                if abs(newTime - self.currentTime) >= 0.1 {
                    self.currentTime = newTime
                }
                let nowPlaying = self.player.timeControlStatus == .playing
                if nowPlaying != self.isPlaying {
                    self.isPlaying = nowPlaying
                }
            }
        }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(0, seconds), duration)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
        currentTime = clamped
    }
}
