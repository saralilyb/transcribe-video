# transcribe-video

A [Claude Code](https://claude.com/claude-code) skill that transcribes video
or audio files to timestamped VTT subtitles locally on Apple Silicon Macs,
using [`mlx-whisper`](https://github.com/ml-explore/mlx-examples/tree/main/whisper).

Everything runs on-device. Nothing is sent to any cloud service.

## What it does

Given a video or audio file, the skill:

1. Confirms the host is an Apple Silicon Mac (refuses to run otherwise).
2. Bootstraps any missing dependencies (Homebrew, ffmpeg, uv, mlx-whisper),
   asking for consent first.
3. Pre-downloads the `whisper-large-v3` model (~1.6 GB) on first run, with
   visible progress.
4. Extracts audio with ffmpeg, normalizing loudness to broadcast standard to
   reduce Whisper hallucinations.
5. Transcribes with parameters tuned to suppress the common failure mode where
   quiet or music-adjacent audio collapses into repeated `[Music]` tokens.
6. Writes a `.vtt` file with word-level timestamps, named after the source.

Supported inputs: `mp4`, `mov`, `mkv`, `mp3`, `m4a`, `wav`, and anything else
ffmpeg can decode.

## Requirements

- Apple Silicon Mac (M1 or newer). MLX is Apple Silicon-only — Intel Macs are
  not supported. (For Intel, see `whisper.cpp` instead.)
- macOS with permission to install Homebrew on first run, if it isn't present.
- A few GB of free disk for the model cache.

The skill installs the rest itself, with consent: Homebrew → ffmpeg → uv →
mlx-whisper.

## Installation as a Claude Code skill

Clone into your Claude Code skills directory:

```sh
git clone https://github.com/saralilyb/transcribe-video.git \
  ~/.claude/skills/transcribe-video
```

Claude Code picks it up automatically on next launch. Then ask Claude something
like "transcribe this video" and point it at a file.

## Standalone use (no Claude)

The script works fine on its own:

```sh
# Check what's installed
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh --check

# Transcribe (skips interactive prompts; required when stdin isn't a TTY)
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y "/absolute/path/to/video.mp4"

# Custom output directory (default: ./transcripts)
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y "/absolute/path/to/video.mp4" "/absolute/path/to/output"
```

## Timing

Approximate, on an M1:

- First-run dependency install: a few minutes.
- First-run model download: several minutes (~1.6 GB).
- Audio extraction: usually under 30 seconds, even for hour-long video.
- Transcription: ~6–12 minutes per hour of audio, depending on chip generation.

Subsequent runs only do extraction + transcription.

## License

[MIT](LICENSE)
