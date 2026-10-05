<p align="center">
  <img src="Resources/AppIcon.png" alt="CallCaption icon" width="128" height="128" style="border-radius: 28px;">
</p>

<h1 align="center">CallCaption</h1>

<p align="center">
  Floating live captions and real-time translation for macOS calls.
</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple" alt="macOS 14+"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="MIT License"></a>
</p>





## Features

- **No virtual audio cables required**: Captures system audio output directly using Apple's `ScreenCaptureKit` framework and your mic through `AVAudioEngine`. Works out of the box with built-in speakers, external mics, and AirPods.
- **On-device speech recognition & translation**: Uses Apple's native speech recognition models (`SFSpeechRecognizer`) and on-device translation. Audio never leaves your machine.
- **Floating HUD**: Stays on top of your call window with two display modes:
  - **Compact Pill**: An unobtrusive 50px status pill showing live caller translations, language selector, mini audio visualizer, and quick controls.
  - **Expanded HUD**: A dual-card split view showing simultaneous transcripts and translations for both speakers.
- **Phone companion (Web / Picture-in-Picture)**: The person you are calling doesn't need to install anything. They can scan a QR code from the app to open a web stream on their phone (iOS Safari or Android Chrome) with Picture-in-Picture support floating over their call.
- **20+ languages supported**: English, Spanish, French, German, Italian, Portuguese, Japanese, Chinese, Korean, Arabic, Russian, and more.
- **Call transcript history**: Keep searchable call logs with speaker labels and timestamps. Export to `.txt` or copy directly to your clipboard.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| <kbd>⌘</kbd> <kbd>M</kbd> | Toggle between Compact Pill and Expanded HUD |
| <kbd>Space</kbd> | Pause / Resume live transcription |
| <kbd>⌘</kbd> <kbd>S</kbd> | Open QR code / Share link for remote mobile caller |
| <kbd>⌘</kbd> <kbd>T</kbd> | Open Call Transcript viewer |
| <kbd>⌘</kbd> <kbd>,</kbd> | Open Permissions & Audio Setup |
| <kbd>⌘</kbd> <kbd>H</kbd> | Bring HUD to front |
| <kbd>⌘</kbd> <kbd>Q</kbd> | Quit CallCaption |

---

## How It Works


1. **Caller Audio Capture**: `AudioCaptureEngine` uses `ScreenCaptureKit` to tap system audio output without muting your speakers or requiring virtual audio devices.
2. **Microphone Capture**: A parallel `AVAudioEngine` tap captures your local microphone.
3. **Speech-to-Text**: Audio buffers are fed into two independent `SFSpeechAudioBufferRecognitionRequest` pipelines.
4. **Translation**: Completed segments are passed to macOS's neural translation session and rendered immediately onto the HUD.
5. **Mobile Companion**: A lightweight embedded HTTP server (`WebCaptionServer`) broadcasts live subtitles via Server-Sent Events (SSE). An automated SSH tunnel (`localhost.run`) provides an HTTPS link and QR code for remote callers.

---

## Requirements

- **macOS 14.0 (Sonoma)** or **macOS 15.0+ (Sequoia)**
- Apple Silicon (M1/M2/M3/M4) recommended; Intel Macs supported
- Xcode Command Line Tools (`xcode-select --install`)

---

## Building from Source

No third-party package managers or external dependencies needed. Everything builds with native Apple frameworks.

```bash
# Clone the repository
git clone https://github.com/samykiassa/Call-Caption.git
cd CallCaption

# Compile the application bundle
./build.sh

# Run CallCaption
./run.sh
```

### Creating a Release DMG

To produce a redistributable, compressed disk image (`CallCaption-Installer.dmg`):

```bash
./package.sh
```

---

## Permissions Setup

Because CallCaption captures both system audio output and your microphone, macOS requires three privacy permissions:

1. **Microphone**: Needed to transcribe your voice.
2. **Speech Recognition**: Needed for Apple's on-device speech-to-text models.
3. **Screen & System Audio Recording**: Required by macOS `ScreenCaptureKit` to tap system audio output from calling apps. *Note: CallCaption only reads the audio stream; it never captures screen pixels or window contents.*

If any permission is missing, open the setup window with <kbd>⌘</kbd> <kbd>,</kbd> or from the menu bar icon to check statuses and jump directly to the relevant System Settings pane.

---

## Project Structure

```text
CallCaption/
├── Sources/
│   ├── AppDelegate.swift              # App lifecycle, menu bar icon, and hotkeys
│   ├── AudioCaptureEngine.swift       # ScreenCaptureKit & AVAudioEngine audio pipelines
│   ├── AudioVisualizerView.swift      # Real-time audio waveform and equalizer view
│   ├── HUDCaptionWindow.swift         # Floating compact & expanded caption HUD
│   ├── LanguageModels.swift           # Supported language definitions and locale codes
│   ├── MobileClientHTML.swift         # Embedded HTML/CSS/JS client for phone browsers
│   ├── PermissionHelper.swift         # macOS TCC authorization helpers
│   ├── PermissionsWindow.swift        # Audio level meter and permissions dashboard
│   ├── ShareWindow.swift              # QR code generator and share link window
│   ├── SpeechRecognitionManager.swift # Apple SFSpeechRecognizer transcription logic
│   ├── TranscriptManager.swift        # In-memory transcript history and file exporter
│   ├── TranscriptWindow.swift         # Transcript history viewer window
│   ├── TranslationEngine.swift        # On-device neural translation engine
│   ├── TunnelManager.swift            # Secure tunnel management for mobile sharing
│   ├── WebCaptionServer.swift         # Embedded HTTP/SSE server for remote viewers
│   └── main.swift                     # NSApplication entry point
├── Resources/
│   ├── AppIcon.icns                   # macOS application icon
│   ├── AppIcon.png                    # High-resolution master icon
│   ├── CallCaption.entitlements       # Sandboxing and audio capture entitlements
│   └── Info.plist                     # App metadata and privacy usage descriptions
├── build.sh                           # Build script with ad-hoc code signing
├── package.sh                         # DMG packaging script
├── run.sh                             # Development launch script
├── .gitignore
├── LICENSE
└── README.md
```

---

## License

Released under the [MIT License](LICENSE).
