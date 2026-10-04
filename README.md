# Absorto

**Proof-of-Work Pomodoro** — a native macOS study timer that can tell a focused session from a distracted one.

A white focus ball shows your attention live. On-device Vision watches for drift (no face, head turned, head down). When a rule holds long enough, one webcam frame and one screen frame go to Gemini, which labels the distraction, rates severity, and speaks a short personal nudge. At the end, Gemini maps where attention broke and quizzes you on that material before the break unlocks.

Built solo with the Gemini API (MLH: Best Use of Gemini API / Best Solo Project).

## Requirements

- macOS 14+
- Xcode 15+ (full Xcode app, not only Command Line Tools)
- Camera + Screen Recording permission
- Optional: Accessibility (for reliable Chrome tab titles)
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

4. On first launch, grant **Camera** and **Screen Recording**. After enabling Screen Recording, quit and reopen the app.

## How to use (demo)

1. Open your study material (e.g. CMPT 371 slides).
2. From the menu bar icon (circle), choose **Open Absorto** or **Start session**.
3. Keep **Demo mode** on for a ~90s session and ~3-second drift hold (no-face needs ~4s so blinks don't fire).
4. Look at the screen during the 5s calibration.
5. Pick up your phone or look away — after the hold, a chime plays, the ball shrinks, and a spoken nudge names what you were studying.
6. A brief glance should not fire.
7. Open an off-topic tab (e.g. a cat video) — window-title check can flag it without a screenshot.
8. End the session (or wait for the timer): attention map → 3 recall questions → break length from ball size + score.

## How I used Gemini

Gemini is called only when judgment is needed, never on a timer. Every call returns JSON with a fixed schema.

| Call | Input | Output | Why |
|------|--------|--------|-----|
| **1. Classify drift + nudge** | Webcam JPEG + screen JPEG + rule fired | `is_false_alarm`, `category`, `severity` (1–5), `studying`, `nudge_text` | Labels the distraction, sets shrink speed, writes a personal nudge that names the material |
| **2. Window title check** | App name + window/tab title + topic | `on_task` (yes/no/unsure), `reason` | Catches off-task tabs from text alone (no screenshot) |
| **3. Spoken nudge** | `nudge_text` | Audio when available; otherwise AVSpeechSynthesizer | Library-style accountability in the moment |
| **4. Focus check** | Drift registry + start/end screen frames | `topic`, `summary`, hotspots, 2 multiple-choice + 1 teach-back | Active recall grounded in what was on screen |
| **5. Grade answers** | MC selections + teach-back | Scores, coaching feedback, next focus | Sets break length with the final ball size |

Also: one screen frame at session start is used to infer the study topic.

Frames leave the Mac only when a rule fires (plus start/end screen frames). Nothing is stored. The API key lives in local `Config.plist` (gitignored).

## Architecture

Native Swift / SwiftUI macOS app — no backend.

| Module | Built with | Job |
|--------|------------|-----|
| App shell | SwiftUI, MenuBarExtra, floating `NSPanel` | Menu bar, session windows, always-on-top focus ball |
| Camera | AVFoundation | Low-res frames ~4–5 fps, late frames dropped |
| Head direction | Vision | Face present, yaw/pitch vs calibration baseline |
| Drift engine | Pure Swift | Hold, cooldown, voice spacing, ball size — XCTest covered |
| Screen | ScreenCaptureKit | One-shot frames at start, end, and drift |
| Window watcher | NSWorkspace + Accessibility title | Event-driven off-task tab detection |
| Gemini client | URLSession + structured JSON | The five calls above |
| Audio | System chime + `AVSpeechSynthesizer` | Chime every time; voice rate-limited |

## Tests

Drift engine checks (no camera/Gemini required; works with Command Line Tools):

```bash
swift run DriftEngineSmoke
```

With full Xcode installed:

```bash
swift test
# or in Xcode: Product → Test
```

## Privacy

- Detection runs on-device with Apple Vision.
- Gemini sees a frame pair only after a held drift (or title text for window checks).
- No accounts, no history, no image storage.
- Aim is an honest focus picture, not surveillance.

## Cut rule / next steps

If scope slips: cut window-title check first, then recall questions (keep attention map), then Gemini voice in favour of the system voice.

After the hackathon: live study room of friends’ focus balls, and App Store release with the Gemini key behind a small server.
