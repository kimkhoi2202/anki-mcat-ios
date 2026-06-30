import Foundation
import AVFoundation
import AnkiKit

/// Plays a card's audio items in order — recorded `[sound:…]` files via
/// `AVAudioPlayer`, and `{{tts}}` text via the system `AVSpeechSynthesizer` —
/// mirroring how Anki autoplays card audio on the front/back and on "Replay
/// audio". AnkiDroid likewise uses the platform's system TTS for `{{tts}}` tags.
/// Starting a new card/side (or `stop()`) cancels anything in flight via a
/// generation counter.
@MainActor
final class CardAudioPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var items: [CardAudio] = []
    private var index = 0
    private var mediaFolder = URL(fileURLWithPath: "/")
    private var generation = 0
    private var playingGeneration = 0
    private var sessionConfigured = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Plays `items` in sequence, stopping any current playback first.
    func play(_ items: [CardAudio], mediaFolder: URL) {
        stop()
        guard !items.isEmpty else { return }
        self.items = items
        self.mediaFolder = mediaFolder
        self.index = 0
        configureSessionIfNeeded()
        advance()
    }

    func stop() {
        generation &+= 1
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        items = []
        index = 0
    }

    private func advance() {
        guard index < items.count else { return }
        let item = items[index]
        index += 1
        switch item {
        case .sound(let filename):
            playFile(mediaFolder.appendingPathComponent(filename))
        case .tts(let text, let lang):
            speak(text, lang: lang)
        }
    }

    private func playFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { advance(); return }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            player = next
            playingGeneration = generation
            next.play()
        } catch {
            advance()
        }
    }

    private func speak(_ text: String, lang: String) {
        let utterance = AVSpeechUtterance(string: text)
        // Anki's TTS tag carries a language (e.g. "en_US"); pick a matching
        // system voice as Android TTS does, falling back to the default.
        let bcp47 = lang.replacingOccurrences(of: "_", with: "-")
        if !bcp47.isEmpty, let voice = AVSpeechSynthesisVoice(language: bcp47) {
            utterance.voice = voice
        }
        playingGeneration = generation
        synthesizer.speak(utterance)
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        // `.playback` so review audio is audible even with the ringer muted.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.playingGeneration == self.generation else { return }
            self.advance()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.playingGeneration == self.generation else { return }
            self.advance()
        }
    }
}
