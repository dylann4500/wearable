import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackController {
    private var player: AVAudioPlayer?
    var playingURL: URL?
    var errorMessage: String?

    func play(url: URL) {
        do {
            if playingURL == url, player?.isPlaying == true {
                player?.pause()
                playingURL = nil
                return
            }

            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            playingURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        player?.stop()
        playingURL = nil
    }
}
