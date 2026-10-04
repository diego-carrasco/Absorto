# Absorto

**Proof-of-Work Pomodoro** — a native macOS study timer that can tell a focused session from a distracted one.

A white focus ball shows your attention live. On-device Vision watches for drift (no face, head turned, head down). You declare what you are studying; Absorto uses tab titles (and Gemini when needed) to catch off-task windows. At the end you **drag in a photo** of your work — Gemini builds a 3-question quiz from it. Break length shrinks with more distractions and missed answers.

Built solo with the Gemini API (MLH: Best Use of Gemini API / Best Solo Project).

## Requirements

- macOS 14+
- Xcode 15+ (full Xcode app, not only Command Line Tools)
- Camera permission (on-device attention only)
- Optional: Accessibility (for reliable browser tab titles)
- Gemini API key ([Google AI Studio](https://aistudio.google.com/))

## Setup

1. Copy the example config and add your key (never commit this file):

```bash
cp Config.example.plist Config.plist
# Edit Config.plist → set GEMINI_API_KEY
```

2. Generate the Xcode project (if needed) and open it:

```bash
xcodegen generate
open Absorto.xcodeproj
```

3. In Xcode: select the **Absorto** scheme → **My Mac** → Run.

4. On first launch, grant **Camera**. Accessibility helps tab-title detection in browsers.

## How to use (demo)

1. Open your study material.
2. From the menu bar icon, choose **Open Absorto**.
3. Hover the crown ring around the ball and scroll/drag to pick **1 / 25 / 50** minutes. Enter **what you are studying today**, then start.
4. Use the short prep window to sit centered and face the webcam, then hold still through calibration.
5. Look away or open an off-topic tab — after the hold / title check, a chime plays and the ball shrinks.
6. End the session (or wait for the timer).
7. **Drag a photo or screenshot** of what you studied into the drop zone. Absorto does not record your screen; Gemini builds 3 questions from the image (topic fallback if Gemini is unavailable).
8. Answer all 3. After submit, a 5-second countdown runs, then the break timer starts with a green/red breakdown of quiz and distraction penalties.

## How I used Gemini

Gemini is used for judgment that needs language understanding — not for continuous vision. Detection of head pose is on-device.

| Call | Input | Output | Why |
|------|--------|--------|-----|
| **Window title check** | Declared topic + app + tab title | `on_task` (yes/no/unsure), `reason` | Catches off-task tabs from text alone |
| **Photo recall quiz** | Study photo JPEG + topic + drift count | 3 multiple-choice questions | Grounds the break quiz in what you actually studied |

Obvious recreational titles are filtered locally so free-tier quota is not wasted. Mid-session head drift uses local nudges only.

The API key lives in local `Config.plist` (gitignored).

## Architecture

Native Swift / SwiftUI macOS app — no backend.

| Module | Built with | Job |
|--------|------------|-----|
| App shell | SwiftUI, MenuBarExtra, floating `NSPanel` | Menu bar, session windows, always-on-top focus ball |
| Camera | AVFoundation | Low-res frames ~4–5 fps for on-device Vision |
| Head direction | Vision | Face present, yaw/pitch vs calibration baseline |
| Drift engine | Pure Swift | Hold, cooldown, voice spacing, ball size, break math |
| Window watcher | NSWorkspace + Accessibility title | Event-driven tab detection |
| Gemini client | URLSession + structured JSON | Title checks + photo quiz |
| Audio | System chime + `AVSpeechSynthesizer` | Chime every drift; on-device spoken nudges |

## Break length

Base **10 minutes** (demo maps minutes to short seconds):

- −1 minute per missed quiz question
- −1 minute per confirmed distraction
- Floor **1 minute**, cap **10 minutes**

After the quiz, Absorto skips a separate “break unlocked” screen: a 5-second countdown shows the penalty lines, then the break timer starts.

## Tests

```bash
swift run DriftEngineSmoke
```

With full Xcode:

```bash
swift test
```

## Privacy

- Attention detection runs on-device with Apple Vision.
- Absorto does **not** automatically record your screen.
- Gemini may see **tab titles** (text) and the **study photo you drag in** for the end-of-session quiz.
- No accounts, no history store. Aim is an honest focus picture, not surveillance.
