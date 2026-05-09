# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

This project uses a `Makefile` (no Justfile).

```bash
make all        # Full build (check + build) — default
make dev        # Build and launch the app
make build      # Build Debug configuration (requires Apple Developer cert)
make local      # Build unsigned for local use — no Apple Developer account needed
make run        # Launch the already-built app
make clean      # Remove all build artifacts and the ~/VoiceInk-Dependencies directory
make check      # Verify git, xcodebuild, swift are installed
```

**First-time setup**: `make all` automatically clones and builds `whisper.cpp` into `~/VoiceInk-Dependencies/` and links the resulting `whisper.xcframework`.

**Local unsigned builds** (`make local`):
- Uses `LocalBuild.xcconfig` + `VoiceInk/VoiceInk.local.entitlements`
- Adds `LOCAL_BUILD` Swift compilation flag — use `#if LOCAL_BUILD` for conditional code paths
- Outputs to `~/Downloads/VoiceInk.app`
- No iCloud/CloudKit, no keychain groups

**Running tests** (via xcodebuild):
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS'
```

## Architecture

### Entry Point & App Bootstrap

`VoiceInk/VoiceInk.swift` (`VoiceInkApp`) owns all top-level `@StateObject`s and wires them together. It initialises the SwiftData `ModelContainer` with schema `[Transcription, VocabularyWord, WordReplacement, SessionMetric]`. `AppDelegate.swift` handles macOS lifecycle events (file open, activation policy).

### Central Engine

`VoiceInkEngine` (`Transcription/Engine/VoiceInkEngine.swift`) is the `@MainActor` `ObservableObject` that coordinates everything during a recording session:
- Holds `Recorder`, `WhisperModelManager`, `TranscriptionModelManager`
- Owns `TranscriptionServiceRegistry` and `TranscriptionPipeline`
- Conforms to `RecorderStateProvider` and `PowerModeStateProvider` (via extensions in `VoiceInkEngine+Protocols.swift`)

### Transcription Pipeline

`TranscriptionPipeline` (`Transcription/Engine/TranscriptionPipeline.swift`) executes the full post-recording flow:
> transcribe → filter → format → word-replace → prompt-detect → AI enhance → paste → save

`TranscriptionServiceRegistry` selects the appropriate service based on `ModelProvider`:
| Provider | Service |
|---|---|
| `.whisper` | `WhisperTranscriptionService` (local, whisper.cpp) |
| `.fluidAudio` | `FluidAudioTranscriptionService` (Parakeet) |
| `.gigaAM` | `GigaAMTranscriptionService` (local, sherpa-onnx + GigaAM v3, Russian-only) |
| `.nativeApple` | `NativeAppleTranscriptionService` |
| all cloud variants | `CloudTranscriptionService` → delegates to a `CloudProvider` |

Local providers come in four flavours: Whisper (whisper.cpp xcframework, multilingual), FluidAudio Parakeet (English), GigaAM v3 (Russian, sherpa-onnx prebuilt xcframework set up by `Scripts/setup-sherpa-onnx.sh`), and native Apple Speech.

### Model Abstraction

`TranscriptionModel` protocol (`Models/TranscriptionModel.swift`) is the unified interface across all providers. `ModelProvider` enum names every supported backend. `TranscriptionModelRegistry` and `TranscriptionModelManager` manage which model is active.

### Streaming

`StreamingTranscriptionService` wraps a `StreamingTranscriptionProvider` (one per cloud provider under `Transcription/Streaming/`). The registry returns a `StreamingTranscriptionSession` (with file-based fallback) when `supportsStreaming` is true for the model.

### Cloud Providers

Each cloud provider (Groq, Deepgram, Mistral, Gemini, ElevenLabs, AssemblyAI, xAI, Cartesia, Soniox, Speechmatics) has a `*Provider.swift` under `Transcription/Cloud/` for file-based transcription and a matching `*StreamingProvider.swift` under `Transcription/Streaming/` for real-time streaming.

### AI Enhancement

`Services/AIEnhancement/AIEnhancementService.swift` post-processes transcripts using an LLM (local via Ollama or remote). `AIEnhancementOutputFilter` strips model artefacts from the output.

### Power Mode

`PowerMode/` implements context-aware settings: `ActiveWindowService` + `BrowserURLService` detect the frontmost app/URL → `PowerModeSessionManager` applies the matching `PowerModeConfig` (model, prompt, enhancement settings).

### SwiftData Models

| Model | Purpose |
|---|---|
| `Transcription` | Each transcription record with text, durations, model metadata |
| `VocabularyWord` | Custom vocabulary entries for the personal dictionary |
| `WordReplacement` | Text replacement rules applied post-transcription |
| `SessionMetric` | Per-session performance and usage metrics |

### Key Managers / Services

- `HotkeyManager` — global keyboard shortcuts via `KeyboardShortcuts`
- `MenuBarManager` — menu bar icon, activation policy
- `RecorderUIManager` — recorder panel visibility (Mini / Notch variants)
- `ModelPrewarmService` — pre-loads the active model after wake from sleep
- `AudioCleanupManager` / `TranscriptionAutoCleanupService` — data retention policies
- `PowerModeManager` (singleton) — persists and provides `PowerModeConfig` list
