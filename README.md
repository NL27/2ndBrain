# 2ⁿᵈ Brain

A **menu-bar-only macOS app** for screen capture, OCR, screen/audio recording, a
clipboard history manager (à la Setapp's *Paste*), local transcription with
speaker attribution — live or after the fact — and connectivity to local & cloud
AI agents (oMLX, Ollama, OpenAI, Anthropic).

Native Swift. No Dock icon, no windows — everything lives in the menu bar.

---

## Features

| Area | What it does |
|------|--------------|
| **Screenshots** | Drag-select any region across **multiple displays**; image is copied straight to the clipboard. (`⌃⌥4`) |
| **OCR** | Drag-select a region; recognized text (on-device, Apple Vision) is copied to the clipboard. (`⌃⌥5`) |
| **Screen recording** | Records a display + **system audio** (ScreenCaptureKit) and the **microphone** simultaneously. Quick-record the screen under the pointer (`⌃⌥6`), or pick a screen from a **visual picker with live previews** (each physical screen is numbered on-screen), or record **all displays at once**. |
| **Audio recording** | Microphone-only capture for quick voice notes / meetings. |
| **Clipboard manager** | Persistent, searchable history of text / images / files with pinning and one-click *paste to frontmost app*. (`⌃⌥V`) |
| **Transcription** | Local transcription of recordings via **whisper.cpp**, **mlx-whisper**, or **[Tiron](https://huggingface.co/Trelis/tiron)**. |
| **Multi-speaker meetings** | **Tiron** (Trelis Research) transcribes *and* attributes speakers in a single decoding pass — up to 8 voices, overlapping speech included — and links them across the whole meeting. State of the art for whole-meeting transcription; no separate diarizer. |
| **Live transcription** | Text appears while people are still talking, via **[heed](https://github.com/isjunrod/heed)** on the Apple Neural Engine (Parakeet + live diarization). 2ⁿᵈ Brain starts the engine itself — nothing to run in a terminal. When you stop, Tiron re-examines the same audio and labels the speakers. (`⌃⌥T`) |
| **AI agents** | Send clipboard/transcript context to **local** (oMLX / Ollama / LM Studio) or **cloud** (OpenAI / Anthropic) models. |
| **VS Code stack** | Setup installs **VS Code** with **Cline**, **Roo Code**, **Kilo Code**, and **AutoGit**, seeds **oMLX** local + **OpenRouter** cloud profiles, wires **multi-instance n8n + engraph + screenpipe** MCP via a registry, and installs **Next.js, NestJS & official n8n skills** on the Desktop for all coding agents. |
| **Screen memory** | Intentional hotkey capture stays in the menu bar; optional **Screenpipe** adds always-on local screen + audio memory. |
| **Knowledge vault** | Markdown second brain at `~/SecondBrain` with **engraph** hybrid search / graph MCP for agents. |
| **Local TTS** | **Piper** neural voices when available; otherwise macOS `say`. |
| **Local-first setup** | First launch downloads engines and models **once** — whisper.cpp, Tiron, heed, oMLX, IDE tooling, vault — then runs offline. |
| **System-aware setup** | It profiles the machine and recommends the best model + backend + AI strategy, on first launch and whenever the hardware/OS changes. |
| **Start at login** | Optional: register the app as a macOS login item so it's in the menu bar right after you log in. (Settings ▸ *Start at Login*) |

### Default hotkeys

| Hotkey | Action |
|--------|--------|
| `⌃⌥4` | Capture area → clipboard |
| `⌃⌥5` | OCR region → clipboard |
| `⌃⌥6` | Record screen + audio (toggle) |
| `⌃⌥T` | Live transcription (toggle) |
| `⌃⌥V` | Clipboard history |

---

## Requirements

- macOS **14.0+** (built & tested on macOS 15.6, Apple Silicon)
- Swift toolchain (Xcode or Command Line Tools — `swift --version`)
- [Homebrew](https://brew.sh) — the one thing setup can't install for you, since
  it needs an admin password
- About **20 GB free** for the engines and models

Everything else (Node, Python 3.12, ffmpeg, whisper.cpp, Tiron, heed, their
models) is downloaded by setup on first launch. Apple Silicon is recommended:
heed's live engine runs on the Neural Engine, and on Intel Macs setup installs
whisper.cpp only.

---

## Install

```bash
# Build + install the app; it sets up its engines on first launch
scripts/install.sh

# Or get the waiting over with now: app + every engine + every model
scripts/install.sh --with-engines

# Include a local LLM (Ollama) so the AI features work offline too
scripts/install.sh --with-engines --with-ollama

# Just one piece (ids: requirements brew node python ffmpeg whisper tiron heed ollama)
scripts/install.sh --only tiron
```

The installer profiles your machine, builds the app, copies it to
`/Applications`, and launches it.

### First launch: making it local-first

The first time 2ⁿᵈ Brain runs, a **setup window** opens and **starts installing
by itself** — you don't have to click anything. It checks this Mac, then
downloads every engine and model:

| Piece | For |
|-------|-----|
| Python 3.12, Node, Bun, ffmpeg | Runtimes the engines need |
| whisper.cpp + a ggml model | Transcribing your own recordings |
| Tiron + its checkpoint (~3 GB) | Who said what, in meetings |
| heed + Neural Engine models | Live transcription with speakers |
| oMLX + oMLX Interpreter | Local LLM server + coding agent |
| VS Code + Cline + Roo Code + Kilo Code + AutoGit | Three AI agents + oMLX/OpenRouter profiles; opens **`~/Desktop/2nd Brain`** on launch |
| Agent skills + MCP registry | Desktop library: `~/Desktop/2nd Brain/Agent Skills/`; OpenRouter under `openrouter/`; thinking under `thinking/`; MCP at `~/Library/Application Support/SecondBrain/mcp/` |
| Screenpipe *(optional)* | Always-on screen/audio memory (`~/Library/Application Support/SecondBrain/bin/screenpipe-start`) |
| Piper TTS | Local speech synthesis (falls back to `say`) |
| `~/SecondBrain` vault + engraph | Searchable knowledge graph for agents |
| Ollama + a model *(optional)* | Extra local LLM runtime alongside oMLX |

It's one long download — several GB — and it only happens once. Each step is
checked before it runs, so closing the window and finishing later picks up where
it left off, and re-running never re-downloads. **Show Details** streams the raw
output if you want to watch.

Skipping before everything is ready brings the window back on the next launch.
Once setup finishes, 2ⁿᵈ Brain warm-starts heed in the background so `⌃⌥T`
opens live captions immediately — no install prompt, no terminal.

Afterwards the app needs no network: transcription, speaker labels, live
captions and (with Ollama) AI all run on this Mac.

Reopen it any time from the menu bar ▸ **Local Engines & Models…**, which also
says how many pieces are still missing. The same work is available as a script:

```bash
scripts/bootstrap.sh --check     # what's installed, changes nothing
scripts/bootstrap.sh             # install whatever is missing (resumes after a drop)
```

### Grant permissions on first use

- **System Settings → Privacy & Security → Screen Recording** → enable *2ⁿᵈ Brain*
- **System Settings → Privacy & Security → Microphone** → enable *2ⁿᵈ Brain*
- **Accessibility** → only needed if you want *auto-paste* from the clipboard
  history (Settings ▸ *Auto-Paste from History*). Without it, clicking a history
  item just copies it so you can press ⌘V yourself — it will **not** nag you.

(Screen Recording is required for screenshots, OCR, and screen recording.)

### Start automatically at login (optional)

Menu bar icon → **Settings** → **Start at Login**. The app registers itself as a
macOS login item (`SMAppService`), so it comes back in the menu bar every time
you log in — silently, since it has no Dock icon or window.

Toggle it off in the same place, or in **System Settings → General → Login Items
& Extensions**, where it also shows up as *2ⁿᵈ Brain*. The menu always reflects
what macOS currently has registered, so changes made in System Settings show up
here too.

This needs the installed app (`/Applications/2nd Brain.app` via
`scripts/install.sh`) — macOS won't register a bare `swift build` binary as a
login item, and the toggle will tell you so.

### Keep permissions across rebuilds (optional, for developers)

Ad-hoc signed builds get a new code hash each rebuild, so macOS forgets your
privacy grants and re-prompts. To avoid that, create a **stable self-signed
identity once**:

```bash
scripts/create-signing-cert.sh
```

You'll approve a trust dialog (login password) once, and the first build after
that will ask to use the key — click **Always Allow**. From then on every
`scripts/build.sh` is signed with the same identity and your Screen
Recording / Microphone grants persist. `install.sh` runs this automatically.

---

## Transcription

There are two separate paths, because "as fast as possible while talking" and
"as accurate as possible afterwards" want different models.

### Recordings — menu ▸ Settings ▸ Transcription Engine

| Engine | Use it for |
|--------|------------|
| **whisper.cpp** | Fastest native option; plain transcript, no speaker labels |
| **mlx-whisper** | Same, on Apple's MLX runtime |
| **Tiron** | Meetings: transcript **and** who said what, up to 8 speakers |

[Tiron](https://huggingface.co/Trelis/tiron) (Trelis Research) uses the
Whisper large-v3 architecture with extra `<|speakerN|>` tokens, so it transcribes
and attributes speakers in one decoding pass instead of bolting a diarizer on
afterwards — which is what lets it handle people talking over each other. The
[harness](https://github.com/TrelisResearch/tiron) then links window-local
speakers into stable meeting-wide identities using ECAPA voice embeddings.

Because Tiron labels speakers itself, there is no separate diarization toggle.
Set **Language** and, if you know it, **Max Speakers** in the Settings submenu.
The first run downloads the ~3 GB checkpoint from Hugging Face, and it decodes
the meeting twice by default, so it's the slow-and-accurate choice.

### Live — `⌃⌥T`

Live transcription is powered by [heed](https://github.com/isjunrod/heed), which
setup installs into
`~/Library/Application Support/SecondBrain/heed`. Press `⌃⌥T` (or menu ▸ *Live
Transcription*) and 2ⁿᵈ Brain **starts the engine itself** if it isn't already
up — the bar shows "loading models" while that happens, which takes a few seconds
the first time in a session. It's stopped again when you quit 2ⁿᵈ Brain.

Text then arrives in the bar at the bottom of the screen as people speak, tagged
with a speaker and a mic/system-audio icon.

### Two engines, one session

heed and Tiron are good at different halves of the problem, so 2ⁿᵈ Brain uses
both:

| | heed, while you talk | Tiron, once you stop |
|---|---|---|
| Speed | Instant, on the Neural Engine | Minutes — it decodes the meeting twice |
| Speakers | Live labels from the mic / system-audio split, plus streaming diarization | Attribution built into decoding; separates voices sharing one channel, overlaps included |

Tiron cannot do this live: it hears 30 seconds at a time and links speakers
*after* seeing the whole meeting. So when a live session ends and more than one
voice was involved, 2ⁿᵈ Brain hands heed's recording to Tiron and saves its
speaker-labelled version alongside:

```
Recordings/live_<timestamp>.txt            heed's transcript
Recordings/live_<timestamp>.speakers.txt   Tiron's, with who said what
```

If the live pass couldn't tell there were several people, 2ⁿᵈ Brain asks
**"Did more than one person speak?"** and runs Tiron when you say yes. Press
**Label Speakers** in the bar any time to force it. Turn the whole thing off in
Settings ▸ *Label Speakers After Live Sessions (Tiron)*, and cap the number of
voices with Settings ▸ *Max Speakers*.

### Screen / audio recordings

2ⁿᵈ Brain's own recorder and heed can't share the microphone, so live captions
aren't available during a screen or audio-only recording. When that recording
stops and auto-transcribe is on, 2ⁿᵈ Brain asks the same question — **"Did more
than one person speak?"** — and runs Tiron for a speaker-labelled transcript, or
whisper.cpp for a plain one.

For meetings where you want speakers *while* people are talking, use **Live
Transcription (`⌃⌥T`)** instead of screen/audio recording.

Worth knowing:

- **heed does the recording** for live sessions — it captures your mic and system
  audio on separate channels, which is how it detects overlap. So 2ⁿᵈ Brain's own
  recorder must be idle; starting a live session while recording is refused.
- The audio file lives in heed's folder. The saved transcript's first line points
  at it.
- **Notes** in the bar opens the session in heed itself, where its AI summaries
  and speaker names live.
- Point 2ⁿᵈ Brain at a different address by changing `heedBaseURL`:
  `defaults write com.dao.secondbrain heedBaseURL http://localhost:5170`

---

## Uninstall

```bash
scripts/uninstall.sh             # remove app + all data, models, prefs, keychain
scripts/uninstall.sh --keep-data # remove the app only
```

## Build manually

```bash
scripts/build.sh release   # produces dist/2nd Brain.app (ad-hoc signed)
swift build                # plain SwiftPM build for development
```

---

## Architecture

```
Sources/2ⁿᵈ Brain/
├── main.swift                  Entry point (accessory app, no Dock icon)
├── AppDelegate.swift           Lifecycle, app-wide info
├── MenuBarController.swift     Status item + the whole menu
├── Core/
│   ├── Logger.swift            os.Logger + file logging
│   ├── Permissions.swift       Screen Recording / Microphone checks
│   ├── HotKeyManager.swift     System-wide hotkeys (Carbon)
│   ├── LaunchAtLogin.swift     Login-item registration (SMAppService)
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
│   ├── TranscriptionManager.swift  WAV conversion + engine invocation
│   ├── HeedClient.swift            heed HTTP + SSE client (live transcription)
│   └── LiveTranscription.swift     Live transcript bar + session control
├── Setup/
│   ├── SetupManager.swift      Runs bootstrap.sh, parses its progress
│   ├── SetupView.swift         First-run setup window
│   └── HeedSupervisor.swift    Starts/stops the local heed server
├── AI/
│   └── AIConnector.swift       OpenAI-compatible + Anthropic + Keychain
└── Settings/
    └── Settings.swift          UserDefaults-backed preferences

scripts/
├── bootstrap.sh   Installs every local engine + model (also bundled in the .app,
│                  which is how the setup window does the work)
├── sync-mcp-registry.py  Applies MCP registry → Cursor snippet + VS Code mcp.json
├── build.sh       Compile + assemble + sign 2ⁿᵈ Brain.app
├── install.sh     Build, install to /Applications, optionally run bootstrap
└── uninstall.sh   Remove the app, and optionally the data
```

### Agent skills library (Desktop)

After setup, browse installed skills at **`~/Desktop/2nd Brain/Agent Skills/`**:

| Subfolder | Contents |
|-----------|----------|
| `nextjs/` | App Router, secure BFF, production platform, cache components, Nest integration |
| `nestjs/` | Best practices, API contracts, workers/transports, patterns, code review, Drizzle ORM |
| `n8n/` | Official n8n skills ([n8n-io/skills](https://github.com/n8n-io/skills)) — start with `using-n8n-skills-official` when using n8n MCP |
| `openrouter/` | Model selection — **`using-openrouter-model-selection`**; default **`openrouter/free`**, upgrade **`openrouter/auto`** |
| `thinking/` | **Start with `thinking-model-router`** — subfolders: `frameworks/`, `reasoning/`, `evaluation/` |
| `mcp/` | MCP registry manifest + `sync-mcp.sh` for multiple n8n instances |

Canonical copies live in `~/.agents/skills/` and sync to Cursor, Cline, Roo & Kilo. VS Code agents read **`AGENTS.md`** at the workspace root (always load `thinking-model-router` first).

### Multi-instance n8n MCP

Setup seeds an MCP registry from your existing `~/.cursor/mcp.json` (if present):

```
~/Library/Application Support/SecondBrain/mcp/
├── registry.json       # n8n instances + other MCP servers (no secrets)
├── local.env           # bearer tokens (chmod 600, created from Cursor on first run)
├── local.env.example
├── sync-mcp.sh         # re-apply after editing registry
└── cursor-mcp.generated.json   # merge into ~/.cursor/mcp.json
```

To add another n8n instance: enable **Instance-level MCP** in n8n, add an entry to `registry.json`, put the token in `local.env`, run `./sync-mcp.sh`.

### VS Code opens 2nd Brain on the Desktop

Setup creates **`~/Desktop/2nd Brain/`** with **`Agent Skills/`** inside and configures VS Code to restore that folder on launch. **`AGENTS.md`**, **`.clinerules/`**, **`.roo/rules/`**, and **`kilo.jsonc`** instruct Cline, Roo & Kilo to always start with **`thinking-model-router`**. The workspace file **`~/Desktop/2nd Brain/2nd Brain.code-workspace`** also includes the knowledge vault. The `code` CLI wrapper opens it when run with no arguments.

You can also double-click **`2nd Brain.code-workspace`** anytime.

Runtime data lives in `~/Library/Application Support/SecondBrain/`
(recordings, clipboard history + images, whisper models, the heed install, logs).

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

## Renamed from Snapture

The app used to be called **Snapture** (bundle ID `com.dao.snapture`). On the
first run of the new build — or when you run `scripts/install.sh` — the data
folder `~/Library/Application Support/Snapture` is moved to `…/2ⁿᵈ Brain`, so
recordings, clipboard history and downloaded models carry over.

Because the bundle ID changed, macOS treats this as a different app, so a few
things need doing once:

- Re-grant **Screen Recording** and **Microphone** to *2ⁿᵈ Brain*
- Re-enter the AI **API key** (the Keychain item moved to `com.dao.secondbrain.ai`)
- Menu settings (model, engine, toggles) fall back to defaults
- Delete the old `/Applications/Snapture.app` and its leftovers if still present:
  `defaults delete com.dao.snapture`

---

## Notes & current limitations

- The app is **ad-hoc signed** for local use. For distribution you'd add a
  Developer ID certificate + notarization in `build.sh`.
- System audio capture requires macOS 13+; microphone is recorded as a separate
  track/file and mixed at transcription time.
- Transcription relies on external engines (whisper.cpp / mlx-whisper / Tiron /
  heed) that setup installs locally. Setup needs the network; after it, they all
  run offline. Without them the app still captures and records, and the menu says
  what's missing.
- Homebrew has to be installed by you — its installer asks for an admin password,
  which the app can't answer. Setup says so instead of failing quietly.
- Tiron hears 30 seconds at a time and caps out at 8 speakers per meeting; its
  timestamps are approximate under heavy overlap, and labels are anonymous
  (`SPEAKER_00`) — it doesn't know people's names.
- Live transcription can't use Tiron *while* talking: it isn't a streaming model.
  heed handles the live half and Tiron re-labels the speakers afterwards.
- **WhisperX was removed** in v0.6.0. Tiron replaces it: same speaker labels, no
  Hugging Face token or separate diarization step. Remove the leftover tool with
  `pipx uninstall whisperx` if you had it.
