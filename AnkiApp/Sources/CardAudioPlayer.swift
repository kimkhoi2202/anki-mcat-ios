import Foundation
import AVFoundation

/// Plays a card's audio files (Anki `[sound:…]` / AV tags) from the collection's
/// media folder, in order, mirroring how every Anki client autoplays card audio
/// on the front/back and on "Replay audio". Starting a new card or side stops
/// whatever was playing.
@MainActor
final class CardAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var queue: [URL] = []
    private var sessionConfigured = false

    /// Plays `filenames` (relative to `mediaFolder`) in sequence, stopping any
    /// current playback first. An empty list just stops.
    func play(_ filenames: [String], mediaFolder: URL) {
        stop()
        guard !filenames.isEmpty else { return }
        queue = filenames.map { mediaFolder.appendingPathComponent($0) }
        configureSessionIfNeeded()
        playNext()
    }

    func stop() {
        player?.stop()
        player = nil
        queue.removeAll()
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        // `.playback` so review audio is audible even with the ringer muted,
        // matching how Anki plays card audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func playNext() {
        guard !queue.isEmpty else { return }
        let url = queue.removeFirst()
        guard FileManager.default.fileExists(atPath: url.path) else {
            playNext()
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            player = next
            next.play()
        } catch {
            playNext()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }
}
