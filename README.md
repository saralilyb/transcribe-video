# transcribe-video

A [Claude Code](https://claude.com/claude-code) skill that transcribes video
or audio files to timestamped VTT subtitles locally, on Apple Silicon Macs
or Linux machines with an NVIDIA GPU (including WSL2). The script dispatches
to a per-platform implementation:

- **macOS (Apple Silicon)** — two engines, picked by language:
  - [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx) (NVIDIA
    Parakeet TDT v3) for English and 24 other European languages —
    substantially faster than Whisper on M-series.
  - [`mlx-whisper`](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
    for Japanese (via [`kotoba-whisper`](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0),
    a Japanese-tuned Whisper) and every other language, and as the `auto`
    fallback (`whisper-large-v3`).

  Parakeet has **no Japanese / no CJK support** — that's the reason for the
  split on macOS.

- **Linux (NVIDIA GPU, including WSL2)** — a single engine:
  - [`whisper-ctranslate2`](https://github.com/Softcatala/whisper-ctranslate2)
    (a faster-whisper-based CLI) on CUDA. One engine handles every
    language: Japanese routes to `kotoba-tech/kotoba-whisper-v2.0-faster`,
    everything else to `Systran/faster-whisper-large-v3`. On a recent
    NVIDIA GPU faster-whisper is fast enough that the Mac-side engine
    split isn't necessary. Language detection runs inside the engine.

Everything runs on-device. Nothing is sent to any cloud service.

## What it does

Given a video or audio file, the skill:

1. Detects the platform (Darwin or Linux) and execs the matching
   implementation. Refuses to run elsewhere, or on Linux without
   a working `nvidia-smi`.
2. Extracts audio with ffmpeg, normalizing loudness to broadcast standard
   (helps both engines, reduces Whisper hallucinations).
3. Picks the language: routes directly if `--language` is given; otherwise
   on macOS detects from a 30-second sample (`whisper-tiny`), while on
   Linux the engine self-detects during transcription.
4. Bootstraps only the dependencies the chosen route needs, asking for
   consent first. macOS: Homebrew → ffmpeg → uv → `parakeet-mlx` and/or
   `mlx-whisper`. Linux: ffmpeg (apt/dnf/pacman) → uv →
   `whisper-ctranslate2`.
5. Pre-downloads the chosen model on first run, with visible progress
   (Parakeet v3 ~2.5 GB on macOS; kotoba-whisper ~1.5 GB;
   whisper-large-v3 ~1.6 GB; CT2 variants are similar on Linux).
6. Transcribes on the available accelerator (MLX on macOS, CUDA on Linux),
   tuned to suppress the Whisper `[Music]`-collapse failure mode.
7. Writes a timestamped `.vtt` file (one cue per sentence), named after the
   source.

Supported inputs: `mp4`, `mov`, `mkv`, `mp3`, `m4a`, `wav`, and anything else
ffmpeg can decode.

## Requirements

**macOS:**

- Apple Silicon Mac (M1 or newer). MLX is Apple Silicon-only — Intel Macs
  are not supported. (For Intel, see `whisper.cpp` instead.)
- Permission to install Homebrew on first run, if it isn't already present.
- A few GB of free disk for the model cache.

The skill installs the rest itself, with consent: Homebrew → ffmpeg → uv →
the engine (`parakeet-mlx` and/or `mlx-whisper`).

**Linux (including WSL2):**

- An NVIDIA GPU with CUDA drivers. On WSL2, install the NVIDIA driver on
  the *Windows host* — there is no Linux-side driver to install inside
  WSL. On native Linux, the proprietary NVIDIA driver for your distro.
  `nvidia-smi` must work; the script refuses to run otherwise.
- A supported package manager for the ffmpeg install: `apt`, `dnf`, or
  `pacman`. Sudo privileges (typical on personal Linux and WSL).
- A few GB of free disk for the model cache (`~/.cache/huggingface/`).

The skill installs the rest itself, with consent: ffmpeg → uv →
`whisper-ctranslate2`.

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

# Transcribe (skips interactive prompts; required when stdin isn't a TTY).
# Default --language auto detects the language, then routes to an engine.
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y "/absolute/path/to/video.mp4"

# Pass the language to skip detection and pick the engine directly.
# English / European → Parakeet (fast); Japanese → kotoba-whisper.
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y -l en "/absolute/path/to/talk.mp4"
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y -l ja "/absolute/path/to/anime.mkv"

# Custom output directory (default: ./transcripts) as the second positional.
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y -l en "/absolute/path/to/video.mp4" "/absolute/path/to/output"

# Advanced: force an engine or a specific model.
bash ~/.claude/skills/transcribe-video/scripts/transcribe-video.sh \
  -y --engine whisper --model mlx-community/whisper-large-v3-turbo "/path/video.mp4"
```

## Timing

Approximate.

**macOS (M1)**:

- First-run dependency install: a few minutes.
- First-run model download: several minutes — Parakeet v3 ~2.5 GB,
  kotoba-whisper ~1.5 GB, whisper-large-v3 ~1.6 GB.
- Audio extraction: usually under 30 seconds, even for hour-long video.
- Language detection (`auto` only): a few seconds (`whisper-tiny`, ~75 MB).
- Transcription: Parakeet is usually a few minutes per hour of audio; Whisper
  is ~6–12 minutes per hour, depending on chip generation.

**Linux (recent NVIDIA GPU)**:

- First-run dependency install: a few minutes.
- First-run model download: a few minutes — CT2 variants of large-v3 and
  kotoba-whisper, similar sizes to the MLX builds.
- Audio extraction: usually under 30 seconds.
- Transcription: typically well under a minute per hour of audio with
  `faster-whisper-large-v3` on a recent NVIDIA GPU. No separate language
  probe — the engine detects internally.

Subsequent runs only do extraction, optional detection, and transcription.

## License

[MIT](LICENSE)
