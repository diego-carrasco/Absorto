import AppKit
import AVFoundation

/// Soft chime + spoken nudge via Apple's on-device `AVSpeechSynthesizer`.
@MainActor
final class AudioService: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastChimeAt = Date.distantPast

    func playChime() {
        if NSSound(named: "Tink")?.play() != true,
           NSSound(named: "Pop")?.play() != true {
            NSSound.beep()
        }
        lastChimeAt = Date()
    }

    /// Short, varied focus call-backs (system voice only).
    func speakFocusNudge(topic: String) {
        speakNudge(FocusNudgeLines.random(topic: topic))
    }

    func speakNudge(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
}

enum FocusNudgeLines {
    static func random(topic: String) -> String {
        let label = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = label.isEmpty ? "your work" : label
        let lines = [
            "Eyes on \(subject).",
            "Come back.",
            "Still with me?",
            "Focus.",
            "Back to \(subject).",
            "Hey — look up.",
            "Stay with it."
        ]
        return lines.randomElement() ?? "Focus."
    }
}
