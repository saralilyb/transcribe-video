---
name: transcribe-video
description: Transcribe video or audio files to timestamped VTT subtitle files locally on Apple Silicon Macs or Linux machines with an NVIDIA GPU (including WSL2). On macOS, English and other European languages use NVIDIA Parakeet (parakeet-mlx, fast) and Japanese uses kotoba-whisper (mlx-whisper); on Linux, a single faster-whisper CUDA path handles everything (kotoba-whisper for Japanese). Use this skill whenever the user wants to transcribe, get a transcript of, get subtitles for, get captions for, extract speech from, or "get the text out of" a video or audio file (mp4, mov, mkv, mp3, m4a, wav, etc.). Also use when the user asks "what's said in this video" or wants to search/summarize spoken content. Bootstraps required dependencies (system package manager + ffmpeg, uv, and the transcription engine) automatically with user consent. All processing happens locally on the user's machine — nothing is sent to any cloud service.
version: 1.0.0
author: Sara Burke
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [transcription, asr, whisper, parakeet, kotoba, vtt, subtitles, captions, video, audio]
    homepage: https://github.com/saralilyb/transcribe-video
    related_skills: []
---

# Transcribe Video

Local video and audio transcription. Produces a timestamped VTT subtitle file (one cue per sentence). The script dispatches to a per-platform implementation:

- **macOS (Apple Silicon)** — two engines, picked by language:
  - **Parakeet** (`parakeet-mlx`, NVIDIA Parakeet TDT v3) for English and 24 other European languages. Substantially faster than Whisper on M-series.
  - **Whisper** (`mlx-whisper`) for Japanese (via `kotoba-whisper`, a Japanese-tuned Whisper) and every other language, and as the `auto` fallback (via `whisper-large-v3`).

  Parakeet has **no Japanese / no CJK support** — that is the whole reason for the split on macOS.

- **Linux (NVIDIA GPU, including WSL2)** — a single engine:
  - **faster-whisper** via the `whisper-ctranslate2` CLI, on CUDA. Handles every language. Japanese routes to `kotoba-tech/kotoba-whisper-v2.0-faster`; everything else to `Systran/faster-whisper-large-v3`. On a recent NVIDIA GPU, faster-whisper is fast enough that the Mac-side engine split isn't necessary. Language detection happens inside the engine when `--language` is omitted; no separate probe phase.

## What this skill does

Runs a bash dispatcher (`scripts/transcribe-video.sh`) that detects the platform and execs the matching implementation (`scripts/transcribe-video-darwin.sh` or `scripts/transcribe-video-linux.sh`). The implementation then:

1. Confirms the platform is supported: Apple Silicon Mac, or Linux with a working `nvidia-smi`. The script will refuse to run otherwise.
2. Extracts audio from the video using ffmpeg, normalizing loudness to broadcast standard (helps both engines, suppresses Whisper hallucinations).
3. Picks the language. If `--language` is given, routes directly. If `auto` (the default): on macOS, detects the language from a 30-second sample using `whisper-tiny` and routes to the right engine; on Linux, the engine self-detects internally during transcription (no probe phase).
4. Installs only the tools the chosen route needs, with consent. On macOS: Homebrew, ffmpeg, uv, and `parakeet-mlx` or `mlx-whisper`. On Linux: ffmpeg (via apt/dnf/pacman), uv, and `whisper-ctranslate2`.
5. Pre-downloads the chosen model on first run, with visible progress, *before* transcription starts — without this the model would download silently with no feedback.
6. Transcribes: Parakeet for European languages on macOS, Whisper-family for Japanese/other on macOS, or `faster-whisper` (CUDA) for everything on Linux.
7. Outputs a `.vtt` file named after the source video, with one timestamped cue per sentence/segment.

The entry point is `scripts/transcribe-video.sh` relative to this skill's directory.

## Phases the user will experience

The script has up to five phases on a fresh machine, each emitting `[notify]` markers on stdout (and on macOS, also Notification Center banners; on Linux these are stdout-only by default):

1. **Audio extraction**. Fast, usually under 30 seconds even for hour-long video.
2. **Language detection** — *macOS only*, and only when `--language` is `auto`. Probes the first 30 seconds with `whisper-tiny` (~75 MB) to decide the engine. Skipped entirely if a language is passed explicitly or on Linux (the Linux engine self-detects).
3. **Dependency install** (skipped if everything needed is present). macOS: Homebrew + ffmpeg + uv + the chosen engine. Linux: ffmpeg via the system package manager + uv + whisper-ctranslate2. A few minutes total either way.
4. **Model download** (skipped if already cached). Sizes vary: Parakeet v3 ~2.5 GB, kotoba-whisper ~1.5 GB, whisper-large-v3 ~1.6 GB (CT2 versions on Linux are similar). tqdm progress bars are visible in stdout.
5. **Transcription**. macOS Parakeet: a few minutes per hour of audio. macOS Whisper: 6–12 minutes per hour. Linux on a recent NVIDIA GPU: usually well under a minute per hour of audio.

On subsequent runs only extraction, (optional) detection, and transcription actually execute.

## How to use it

### Step 1: Locate the video file

If the user mentions a file by name without giving a full path, ask where it lives or check obvious locations (`~/Movies`, `~/Downloads`, `~/Desktop`). Always pass an absolute path to the script.

### Step 2: Check what's already installed

Run the script in check mode first to see what dependencies are present:

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh --check
```

Replace `<SKILL_DIR>` with the actual absolute path to this skill's directory (typically `~/.claude/skills/transcribe-video` for Claude Code installs).

### Step 3: Get user consent for any installs

If anything is missing, tell the user *plainly* what would be installed and roughly why. The list depends on the platform:

On **macOS**:
- **Homebrew**: macOS package manager, needed to install ffmpeg
- **ffmpeg**: extracts audio from video files
- **uv**: fast Python package manager from Astral, needed to install the engine
- **parakeet-mlx**: the fast transcription engine, used for English and other European languages
- **mlx-whisper**: the transcription engine for Japanese (kotoba-whisper) and other languages, and for `auto` language detection

On **Linux** (apt / dnf / pacman is detected automatically):
- **ffmpeg**: extracts audio from video files (installed via the system package manager, requires sudo)
- **uv**: fast Python package manager from Astral, needed to install the engine
- **whisper-ctranslate2**: the faster-whisper-based transcription engine, runs on the local NVIDIA GPU

Only the tools the chosen route actually needs get installed (on macOS, an English clip won't install mlx-whisper unless `--language auto` is used for detection). Mention that everything runs locally and nothing is sent to any cloud service. On Linux, mention that ffmpeg install will prompt for sudo. Ask the user to confirm before proceeding.

### Step 4: Run the transcription

After confirmation, run the script with `-y` to skip interactive prompts (required because the script can't read stdin when invoked this way):

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y "/absolute/path/to/video.mp4"
```

**Pass `--language` when you know the content language.** On macOS this skips the 30-second detection probe and routes straight to the right engine — and for English/European content it unlocks the fast Parakeet path that the user is here for. On Linux there's no probe phase regardless, but `--language` still helps the engine pick the right tokenizer and skip its internal detection step. The user usually tells you the language ("transcribe this Japanese video"); use it.

```bash
# English (or fr/de/es/it/pt/nl/pl/…)
# macOS: → Parakeet, fast. Linux: → faster-whisper-large-v3 on CUDA.
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l en "/absolute/path/to/video.mp4"

# Japanese → kotoba-whisper on both platforms
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l ja "/absolute/path/to/video.mp4"
```

Leaving `--language` off (the default `auto`) is fine when you genuinely don't know the language — it detects, then routes. To specify a different output directory (default is `./transcripts` relative to the current working directory), pass it as the second positional argument:

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l en "/absolute/path/to/video.mp4" "/absolute/path/to/output"
```

### Step 5: Set expectations

Tell the user roughly how long this will take *before* it starts:

- First-time install of dependencies: a few minutes for ffmpeg + uv + the engine. On macOS, Homebrew is the package manager; on Linux it's the system package manager (apt, dnf, or pacman) plus a sudo prompt for the ffmpeg install.
- First-time model download, depending on language: Parakeet v3 ~2.5 GB (macOS only, English/European), kotoba-whisper ~1.5 GB (Japanese), whisper-large-v3 ~1.6 GB (other). Several more minutes depending on connection speed.
- Each transcription: on macOS, Parakeet is a few minutes per hour of audio and Whisper is roughly 6–12 minutes per hour. On Linux with a recent NVIDIA GPU, faster-whisper typically runs well under a minute per hour of audio.

Also mention (macOS only): macOS may show a one-time prompt asking whether to allow notifications from "Script Editor" or whichever process is running osascript. Tell the user to allow it if they want native banner notifications during long phases. The script works fine either way; permission only affects whether the macOS Notification Center banners appear. On Linux there are no native banners — Claude relays progress from the `[notify]` stdout markers.

### Step 6: Relay progress to the user

The script emits `[notify]` markers on stdout at each milestone. On macOS, the same milestones also fire a Notification Center banner via `osascript`; on Linux, the stdout markers are the only channel. Either way Claude should relay them conversationally as they appear — the user often won't be watching the terminal.

When you see a `[notify]` line in the script output, surface that milestone to the user in a short message. Don't dump the raw `[notify]` text. Translate. For example:

- `[notify] Transcription setup: Detecting language from a 30-second sample...` → "Checking what language this is so I can pick the fastest engine."
- `[notify] Transcription setup: Downloading speech recognition model (~2.5 GB)...` → "Downloading the transcription model now. It's a one-time download. Should take a few minutes."
- `[notify] Transcription: Starting transcription with Parakeet...` → "Model's ready. Starting the transcription now."
- `[notify] Transcription complete: Transcript saved: <name>.vtt` → "Done. Your transcript is saved at `<full path>`."

### Step 7: Hand off the result

The script prints the absolute path of the resulting `.vtt` file at the end. Pass that to the user. If they want a plain-text version without timestamps, strip the timestamp lines from the VTT (the VTT has one timestamped cue per sentence; there's no plain-text output mode).

## Notes for non-technical users

The script is designed so a non-technical user can have Claude run it without ever opening a terminal themselves. Communicate clearly:

- Use plain language. "This will install some software you don't have yet" rather than "bootstrapping dependencies."
- Don't dump command output unless something fails. Summarize the result.
- If an install fails, tell the user to restart their terminal (or restart Claude Desktop, depending on context) and try again. The most common cause is `PATH` not picking up newly-installed binaries.

## Troubleshooting

**"Cannot continue without X"**: The user declined to install a required dependency. Ask if they want to reconsider, or stop.

**Script fails with `command not found: uv` or similar after a fresh install**: The new binary isn't on PATH yet. The script tries to handle this, but if it fails, suggest the user restart their terminal session and re-run.

**Output is just `[Music]` or repeated nonsense** (Whisper paths only — Japanese/other): The audio is unusually quiet, has heavy background music, or has long silences. The script's `loudnorm` filter and `--no-speech-threshold 0.3` handle most cases, but for severe cases consider preprocessing with a VAD (Voice Activity Detection) tool like Silero, or switching to faster-whisper which has VAD built in. This is outside the scope of this skill. Parakeet doesn't exhibit the `[Music]`-collapse failure mode.

**Garbled output on a Japanese (or Chinese/Korean) file**: Parakeet has **no CJK support** — it only does English and 24 European languages. If a CJK clip was routed to Parakeet (e.g. via `--language` set wrong, `--engine parakeet`, or a misfire in `auto` detection), re-run with the correct language, e.g. `-l ja`. Japanese routes to `kotoba-whisper`; other non-European languages route to `whisper-large-v3`.

**Wrong engine chosen by `auto`** (*macOS only*): Detection probes only the first 30 seconds, so a clip that opens in a different language than its body can mis-route. Re-run with an explicit `--language` to override. Explicit `--language` always skips detection. On Linux there's only one engine, so this doesn't apply — but explicit `--language` still helps the engine pick the right tokenizer.

**Want to force a specific model or engine**: On macOS, `--engine parakeet|whisper` forces the engine and `--model <hf-repo>` forces a specific model (e.g. `--model mlx-community/whisper-large-v3-turbo`). On Linux, only `--engine whisper` is meaningful; `--model` must point at a CTranslate2-converted Whisper repo (e.g. `Systran/faster-whisper-large-v3-turbo`).

**"nvidia-smi not found" or "nvidia-smi failed" on Linux**: The script requires a working NVIDIA driver. On WSL2, the driver lives on the *Windows host* — install the latest NVIDIA Windows driver, then in WSL run `nvidia-smi` to confirm it works. There's no Linux-side NVIDIA driver to install in WSL2. On native Linux, install the proprietary NVIDIA driver for your distro. If `nvidia-smi` is installed but fails on WSL2, try `wsl --shutdown` from Windows and reopen.

**"No supported package manager detected" on Linux**: The script only knows how to install ffmpeg via apt-get, dnf, or pacman. On other distros (Alpine, NixOS, etc.) install ffmpeg manually with the system tools and re-run.

**Intel Mac, Linux without NVIDIA GPU, or unsupported OS**: This skill won't work. Direct the user to whisper.cpp (`brew install whisper-cpp` on Mac, package-managed on Linux) as a CPU-friendly alternative.
