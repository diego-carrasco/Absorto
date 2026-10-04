import AppKit
import Foundation

/// Minimal Apple-style UI sounds using system `NSSound` assets only.
@MainActor
final class AudioService: ObservableObject {
    private var lastChimeAt = Date.distantPast

    // MARK: - Public cues

    /// Soft system chime when focus drifts (white ball starts shrinking).
    func playChime() {
        playSystem("Tink", volume: 0.35)
        lastChimeAt = Date()
    }

    /// Digital-crown detent when the session-length ring ticks.
    func playCrownTick() {
        playSystem("Tink", volume: 0.22)
    }

    /// Last 5 seconds of the study timer — quiet, even ticks; final second slightly clearer.
    func playCountdownTick(secondsRemaining: Int) {
        if secondsRemaining <= 1 {
            playSystem("Glass", volume: 0.28)
        } else {
            playSystem("Tink", volume: 0.18)
        }
    }

    /// White ball has vanished; red warning begins.
    func playWarningRise() {
        playSystem("Bottle", volume: 0.28)
    }

    /// Red warning held long enough — session paused.
    func playSessionHalted() {
        playSystem("Submarine", volume: 0.32)
    }

    /// Break ambience removed — kept as no-ops for call-site compatibility.
    func startElevatorMusic() {}
    func stopElevatorMusic() {}

    // MARK: - Private

    private func playSystem(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            if name != "Tink" {
                playSystem("Tink", volume: volume)
            }
            return
        }
        guard let clone = sound.copy() as? NSSound else {
            sound.volume = volume
            sound.play()
            return
        }
        clone.volume = max(0, min(1, volume))
        clone.play()
    }
}
