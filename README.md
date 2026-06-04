# Snapture

A **menu-bar-only macOS app** for screen capture, OCR, screen/audio recording, a
clipboard history manager (à la Setapp's *Paste*), local transcription with
speaker diarization, and connectivity to local & cloud AI agents — inspired by
CleanShot X.

Native Swift. No Dock icon, no windows — everything lives in the menu bar.

---

## Features

| Area | What it does |
|------|--------------|
| **Screenshots** | Drag-select any region across **multiple displays**; image is copied straight to the clipboard. (`⌃⌥4`) |
| **OCR** | Drag-select a region; recognized text (on-device, Apple Vision) is copied to the clipboard. (`⌃⌥5`) |
| **Screen recording** | Records a display + **system audio** (ScreenCaptureKit) and the **microphone** simultaneously. (`⌃⌥6`) |
| **Audio recording** | Microphone-only capture for quick voice notes / meetings. |
| **Clipboard manager** | Persistent, searchable history of text / images / files with pinning and one-click *paste to frontmost app*. (`⌃⌥V`) |
| **Transcription** | Local transcription of recordings via **whisper.cpp**, **WhisperX**, or **mlx-whisper**. |
| **Speaker diarization** | Optional speaker labels via WhisperX. |
| **AI agents** | Send clipboard/transcript context to **local** (Ollama / LM Studio / llama.cpp) or **cloud** (OpenAI / Anthropic) models. |
| **System-aware setup** | On first launch (and when hardware/OS changes) it profiles the machine and recommends the best model + backend + AI strategy. |

### Default hotkeys

| Hotkey | Action |
|--------|--------|
| `⌃⌥4` | Capture area → clipboard |
| `⌃⌥5` | OCR region → clipboard |
| `⌃⌥6` | Record screen + audio (toggle) |
| `⌃⌥V` | Clipboard history |

---

## Requirements

- macOS **14.0+** (built & tested on macOS 15.6, Apple Silicon)
- Swift toolchain (Xcode or Command Line Tools — `swift --version`)
- Optional, for transcription: [Homebrew](https://brew.sh), `whisper-cpp`, or `whisperx` (handled by the installer)

---

## Install

```bash
# App only
scripts/install.sh

# App + whisper.cpp + a model (recommended for transcription)
scripts/install.sh --with-whisper --model small.en

# App + WhisperX for speaker diarization
scripts/install.sh --with-whisperx
```

The installer profiles your machine, builds the app, copies it to
`/Applications`, optionally installs transcription engines/models, and launches
it.

### Grant permissions on first use

- **System Settings → Privacy & Security → Screen Recording** → enable *Snapture*
- **System Settings → Privacy & Security → Microphone** → enable *Snapture*

(Screen Recording is required for screenshots, OCR, and screen recording.)

## Uninstall

```bash
scripts/uninstall.sh             # remove app + all data, models, prefs, keychain
scripts/uninstall.sh --keep-data # remove the app only
```

## Build manually

```bash
scripts/build.sh release   # produces dist/Snapture.app (ad-hoc signed)
swift build                # plain SwiftPM build for development
```

---

## Architecture

```
Sources/Snapture/
├── main.swift                  Entry point (accessory app, no Dock icon)
├── AppDelegate.swift           Lifecycle, app-wide info
├── MenuBarController.swift     Status item + the whole menu
├── Core/
│   ├── Logger.swift            os.Logger + file logging
│   ├── Permissions.swift       Screen Recording / Microphone checks
│   ├── HotKeyManager.swift     System-wide hotkeys (Carbon)
│   └── SystemProfiler.swift    Hardware probe + recommendations
├── Capture/
│   ├── SelectionOverlay.swift  Multi-display drag-to-select overlay
│   ├── ScreenshotManager.swift Region capture → clipboard (ScreenCaptureKit)
│   └── OCRManager.swift        Vision OCR → clipboard
├── Recording/
│   ├── ScreenRecorder.swift    Display + system audio → .mov
│   ├── AudioRecorder.swift     Microphone → .m4a
│   └── RecordingCoordinator.swift  Orchestration + auto-transcribe
├── Clipboard/
│   ├── ClipboardManager.swift  Pasteboard monitor + persisted history
│   └── ClipboardHistoryView.swift  SwiftUI quick-access panel
├── Transcription/
│   └── TranscriptionManager.swift  WAV conversion + engine invocation
├── AI/
│   └── AIConnector.swift       OpenAI-compatible + Anthropic + Keychain
└── Settings/
    └── Settings.swift          UserDefaults-backed preferences
```

Runtime data lives in `~/Library/Application Support/Snapture/`
(recordings, clipboard history + images, whisper models, logs).

---

## Versioning & restore points

This project uses **git** so you can always roll back if something breaks.

```bash
# See tagged releases / restore points
git tag

# Inspect history
git log --oneline

# Roll the working tree back to a known-good version (non-destructive)
git checkout v0.1.0

# Return to latest
git checkout main

# Hard reset to a tag (destructive — discards uncommitted work)
git reset --hard v0.1.0
```

**Workflow:** before each risky change, commit; after a feature works, tag it
(`git tag -a vX.Y.Z -m "..."`). The app's `CFBundleShortVersionString` in
`Resources/Info.plist` should track the same version.

---

## AI configuration

Menu → **AI**:

- **Provider**: Local (OpenAI-compatible) / OpenAI / Anthropic
- **Set Base URL / Model**: e.g. `http://localhost:11434/v1` + `llama3.1` for Ollama
- **Set API Key**: stored in the macOS Keychain (cloud providers only)
- **Ask AI about Clipboard**: sends your prompt with the latest clipboard text as context

---

## Notes & current limitations

- The app is **ad-hoc signed** for local use. For distribution you'd add a
  Developer ID certificate + notarization in `build.sh`.
- System audio capture requires macOS 13+; microphone is recorded as a separate
  track/file and mixed at transcription time.
- Transcription/diarization rely on external engines installed via the
  installer; without them the app still captures and records, and tells you what
  to install.
