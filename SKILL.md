---
name: transcribe-video
description: Transcribe video or audio files to timestamped VTT subtitle files locally on Apple Silicon Macs. English and other European languages use NVIDIA Parakeet (parakeet-mlx, fast); Japanese uses kotoba-whisper and other languages use Whisper (mlx-whisper). Use this skill whenever the user wants to transcribe, get a transcript of, get subtitles for, get captions for, extract speech from, or "get the text out of" a video or audio file (mp4, mov, mkv, mp3, m4a, wav, etc.). Also use when the user asks "what's said in this video" or wants to search/summarize spoken content. Bootstraps required dependencies (Homebrew, ffmpeg, uv, and the transcription engine) automatically with user consent. All processing happens locally on the user's machine — nothing is sent to any cloud service.
---

# Transcribe Video

Local video and audio transcription on Apple Silicon. Produces a timestamped VTT subtitle file (one cue per sentence). Two engines, picked by language:

- **Parakeet** (`parakeet-mlx`, NVIDIA Parakeet TDT v3) for English and 24 other European languages. Substantially faster than Whisper.
- **Whisper** (`mlx-whisper`) for Japanese (via `kotoba-whisper`, a Japanese-tuned Whisper) and every other language, and as the `auto` fallback (via `whisper-large-v3`).

Parakeet has **no Japanese / no CJK support** — that is the whole reason for the split.

## What this skill does

Runs a bash script that:

1. Confirms the user is on an Apple Silicon Mac (the script will refuse to run otherwise)
2. Extracts audio from the video using ffmpeg, normalizing loudness to broadcast standard (helps both engines, suppresses Whisper hallucinations)
3. Picks the language. If `--language` is given, routes directly; if `auto` (the default), detects the language from a 30-second sample using `whisper-tiny`, then routes to the right engine
4. Installs only the tools the chosen route needs (Homebrew, ffmpeg, uv, and `parakeet-mlx` or `mlx-whisper`), with consent
5. Pre-downloads the chosen model on first run, with visible progress, *before* transcription starts — without this the model would download silently with no feedback
6. Transcribes: Parakeet for European languages (auto language ID, long-audio chunking) or Whisper for Japanese/other (tuned to suppress the `[Music]`-collapse failure mode)
7. Outputs a `.vtt` file named after the source video, with one timestamped cue per sentence/segment

The script is at `scripts/transcribe-video.sh` relative to this skill's directory.

## Phases the user will experience

The script has up to five phases on a fresh machine, each emitting `[notify]` markers on stdout *and* macOS Notification Center banners:

1. **Audio extraction**. Fast, usually under 30 seconds even for hour-long video.
2. **Language detection** (only when `--language` is `auto`). Probes the first 30 seconds with `whisper-tiny` (~75 MB) to decide the engine. Skipped entirely if a language is passed explicitly.
3. **Dependency install** (skipped if everything needed is present). Homebrew + ffmpeg + uv + the chosen engine (`parakeet-mlx` or `mlx-whisper`). A few minutes total.
4. **Model download** (skipped if already cached). Depends on the engine: Parakeet v3 ~2.5 GB, kotoba-whisper ~1.5 GB, whisper-large-v3 ~1.6 GB. Several minutes on a typical home connection. tqdm progress bars are visible in stdout.
5. **Transcription**. Parakeet: usually a few minutes per hour of audio. Whisper: roughly 6-12 minutes per hour, depending on chip generation.

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

If anything is missing, tell the user *plainly* what would be installed and roughly why:

- **Homebrew**: macOS package manager, needed to install ffmpeg
- **ffmpeg**: extracts audio from video files
- **uv**: fast Python package manager from Astral, needed to install the engine
- **parakeet-mlx**: the fast transcription engine, used for English and other European languages
- **mlx-whisper**: the transcription engine for Japanese (kotoba-whisper) and other languages, and for `auto` language detection

Only the tools the chosen route actually needs get installed (e.g. an English clip won't install mlx-whisper unless `--language auto` is used for detection). Mention that everything runs locally and nothing is sent to any cloud service. Ask the user to confirm before proceeding.

### Step 4: Run the transcription

After confirmation, run the script with `-y` to skip interactive prompts (required because the script can't read stdin when invoked this way):

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y "/absolute/path/to/video.mp4"
```

**Pass `--language` when you know the content language.** This skips the 30-second detection probe and routes straight to the right engine — and for English/European content it unlocks the fast Parakeet path that the user is here for. The user usually tells you the language ("transcribe this Japanese video"); use it.

```bash
# English (or fr/de/es/it/pt/nl/pl/…) → Parakeet, fast
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l en "/absolute/path/to/video.mp4"

# Japanese → kotoba-whisper
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l ja "/absolute/path/to/video.mp4"
```

Leaving `--language` off (the default `auto`) is fine when you genuinely don't know the language — it detects, then routes. To specify a different output directory (default is `./transcripts` relative to the current working directory), pass it as the second positional argument:

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y -l en "/absolute/path/to/video.mp4" "/absolute/path/to/output"
```

### Step 5: Set expectations

Tell the user roughly how long this will take *before* it starts:

- First-time install of dependencies: a few minutes for Homebrew + ffmpeg + uv + the engine
- First-time model download, depending on language: Parakeet v3 ~2.5 GB (English/European), kotoba-whisper ~1.5 GB (Japanese), whisper-large-v3 ~1.6 GB (other). Several more minutes depending on connection speed
- Each transcription: Parakeet is usually a few minutes per hour of audio; Whisper is roughly 6-12 minutes per hour, depending on the chip generation

Also mention: macOS may show a one-time prompt asking whether to allow notifications from "Script Editor" or whichever process is running osascript. Tell the user to allow it if they want native banner notifications during long phases. The script works fine either way; permission only affects whether the macOS Notification Center banners appear.

### Step 6: Relay progress to the user

The script emits dual-channel notifications. macOS Notification Center handles user-facing banners. Claude sees the same milestones on stdout, tagged with `[notify]`, and should relay them conversationally as they appear — this matters because the osascript notifications may not fire in every environment, and the user often won't be watching the terminal.

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

**Wrong engine chosen by `auto`**: Detection probes only the first 30 seconds, so a clip that opens in a different language than its body can mis-route. Re-run with an explicit `--language` to override. Explicit `--language` always skips detection.

**Want to force a specific model or engine**: `--engine parakeet|whisper` forces the engine; `--model <hf-repo>` forces a specific model (e.g. `--model mlx-community/whisper-large-v3-turbo` for a faster multilingual Whisper, or a quantized Parakeet build to save disk).

**Intel Mac**: This skill won't work. MLX is Apple Silicon-only. Direct the user to whisper.cpp (`brew install whisper-cpp`) as an alternative that runs on Intel.
