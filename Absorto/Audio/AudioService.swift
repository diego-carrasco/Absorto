import AppKit
import AVFoundation

/// Soft chime + spoken nudge (AVSpeechSynthesizer fallback when Gemini TTS unavailable).
@MainActor
final class AudioService: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastChimeAt = Date.distantPast

    func playChime() {
        // Built-in system sound — soft and reliable for the demo
        if NSSound(named: "Tink")?.play() != true,
           NSSound(named: "Pop")?.play() != true {
            NSSound.beep()
        }
        lastChimeAt = Date()
    }

    func speakNudge(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        // Prefer a natural English voice if available
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func speakNudge(data: Data?, text: String) {
        // Gemini TTS audio path reserved; fall back to system voice.
        if let data, !data.isEmpty {
            // Attempt to play raw audio if a WAV/container arrives later
            if let sound = NSSound(data: data) {
                sound.play()
                return
            }
        }
        speakNudge(text)
    }
}
