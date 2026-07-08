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

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            #endif

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let byteSize = attributes[.size] as? NSNumber, byteSize.intValue > 44 else {
                throw PlaybackError.invalidAudioFile
            }

            let newPlayer = try AVAudioPlayer(contentsOf: url)
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                throw PlaybackError.couldNotStart
            }
            player = newPlayer
            playingURL = url
            errorMessage = nil
        } catch {
            errorMessage = "This audio file could not be decoded. The app will replace invalid copies during the next wearable sync. \(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        playingURL = nil
    }
}

private enum PlaybackError: LocalizedError {
    case invalidAudioFile
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .invalidAudioFile: "The downloaded audio file is empty or incomplete."
        case .couldNotStart: "The audio player could not start."
        }
    }
}
