---
name: transcribe-video
description: Transcribe video or audio files to timestamped VTT subtitle files locally on Apple Silicon Macs using mlx-whisper. Use this skill whenever the user wants to transcribe, get a transcript of, get subtitles for, get captions for, extract speech from, or "get the text out of" a video or audio file (mp4, mov, mkv, mp3, m4a, wav, etc.). Also use when the user asks "what's said in this video" or wants to search/summarize spoken content. Bootstraps required dependencies (Homebrew, ffmpeg, uv, mlx-whisper) automatically with user consent. All processing happens locally on the user's machine — nothing is sent to any cloud service.
---

# Transcribe Video

Local video and audio transcription using mlx-whisper on Apple Silicon. Produces a word-level timestamped VTT subtitle file.

## What this skill does

Runs a bash script that:

1. Confirms the user is on an Apple Silicon Mac (the script will refuse to run otherwise)
2. Checks for required tools (Homebrew, ffmpeg, uv, mlx-whisper) and installs any that are missing
3. Pre-downloads the `whisper-large-v3` model (~1.6 GB) on first run, with visible progress, *before* the transcription starts. This is a deliberate split: without it, the model would download silently inside mlx_whisper with no feedback.
4. Extracts audio from the video using ffmpeg, normalizing loudness to broadcast standard to prevent Whisper hallucinations
5. Transcribes with parameters tuned to suppress the common failure mode where quiet or music-adjacent audio collapses into repeated `[Music]` tokens
6. Outputs a `.vtt` file named after the source video, with word-level timestamps

The script is at `scripts/transcribe-video.sh` relative to this skill's directory.

## Phases the user will experience

The script has up to four sequential phases on a fresh machine, each emitting `[notify]` markers on stdout *and* macOS Notification Center banners:

1. **Dependency install** (skipped if everything is already installed). Homebrew + ffmpeg + uv + mlx-whisper. A few minutes total.
2. **Model download** (skipped if already cached). ~1.6 GB. Several minutes on a typical home connection. tqdm progress bars are visible in stdout.
3. **Audio extraction**. Fast, usually under 30 seconds even for hour-long video.
4. **Transcription**. Roughly 6-12 minutes per hour of audio, depending on chip generation.

On subsequent runs only phases 3 and 4 actually execute.

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
- **uv**: fast Python package manager from Astral, needed to install mlx-whisper
- **mlx-whisper**: the actual transcription engine, runs locally on Apple Silicon

Mention that everything runs locally and nothing is sent to any cloud service. Ask the user to confirm before proceeding.

### Step 4: Run the transcription

After confirmation, run the script with `-y` to skip interactive prompts (required because the script can't read stdin when invoked this way):

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y "/absolute/path/to/video.mp4"
```

To specify a different output directory (default is `./transcripts` relative to the current working directory):

```bash
bash <SKILL_DIR>/scripts/transcribe-video.sh -y "/absolute/path/to/video.mp4" "/absolute/path/to/output"
```

### Step 5: Set expectations

Tell the user roughly how long this will take *before* it starts:

- First-time install of dependencies: a few minutes for Homebrew + ffmpeg + uv + mlx-whisper
- First-time model download: ~1.6 GB, several more minutes depending on connection speed
- Each transcription: roughly 6-12 minutes per hour of audio, depending on the chip generation

Also mention: macOS may show a one-time prompt asking whether to allow notifications from "Script Editor" or whichever process is running osascript. Tell the user to allow it if they want native banner notifications during long phases. The script works fine either way; permission only affects whether the macOS Notification Center banners appear.

### Step 6: Relay progress to the user

The script emits dual-channel notifications. macOS Notification Center handles user-facing banners. Claude sees the same milestones on stdout, tagged with `[notify]`, and should relay them conversationally as they appear — this matters because the osascript notifications may not fire in every environment, and the user often won't be watching the terminal.

When you see a `[notify]` line in the script output, surface that milestone to the user in a short message. Don't dump the raw `[notify]` text. Translate. For example:

- `[notify] Transcription setup: Downloading speech recognition model (~1.6 GB)...` → "Downloading the transcription model now. This is about 1.6 GB and only happens once. Should take a few minutes."
- `[notify] Transcription: Starting transcription...` → "Model's downloaded. Starting the actual transcription. This part takes about 6-12 minutes per hour of audio."
- `[notify] Transcription complete: Transcript saved: <name>.vtt` → "Done. Your transcript is saved at `<full path>`."

### Step 7: Hand off the result

The script prints the absolute path of the resulting `.vtt` file at the end. Pass that to the user. If they want a plain-text version without timestamps, either re-run without the `--word-timestamps` flag (you'd need to edit the script) or strip timestamps from the VTT manually.

## Notes for non-technical users

The script is designed so a non-technical user can have Claude run it without ever opening a terminal themselves. Communicate clearly:

- Use plain language. "This will install some software you don't have yet" rather than "bootstrapping dependencies."
- Don't dump command output unless something fails. Summarize the result.
- If an install fails, tell the user to restart their terminal (or restart Claude Desktop, depending on context) and try again. The most common cause is `PATH` not picking up newly-installed binaries.

## Troubleshooting

**"Cannot continue without X"**: The user declined to install a required dependency. Ask if they want to reconsider, or stop.

**Script fails with `command not found: uv` or similar after a fresh install**: The new binary isn't on PATH yet. The script tries to handle this, but if it fails, suggest the user restart their terminal session and re-run.

**Output is just `[Music]` or repeated nonsense**: The audio is unusually quiet, has heavy background music, or has long silences. The script's `loudnorm` filter and `--no-speech-threshold 0.3` handle most cases, but for severe cases consider preprocessing with a VAD (Voice Activity Detection) tool like Silero, or switching to faster-whisper which has VAD built in. This is outside the scope of this skill.

**Wrong language detected**: The script forces English (`--language en`). If the source is in another language, the script needs to be modified or the language flag overridden. For now, edit the script's `mlx_whisper` invocation directly.

**Intel Mac**: This skill won't work. MLX is Apple Silicon-only. Direct the user to whisper.cpp (`brew install whisper-cpp`) as an alternative that runs on Intel.
