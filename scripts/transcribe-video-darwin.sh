#!/usr/bin/env bash
#
# transcribe-video-darwin.sh
#
# Apple Silicon implementation of the transcribe-video skill. Invoked by
# the platform dispatcher at scripts/transcribe-video.sh. Two engines,
# picked by language:
#
#   - parakeet-mlx  (NVIDIA Parakeet TDT v3) for English and 24 other
#     European languages. Much faster than Whisper on M-series.
#   - mlx-whisper   for Japanese (kotoba-whisper) and every other
#     language, and for `auto` fallback.
#
# Self-bootstraps all dependencies (Homebrew, ffmpeg, uv, and whichever
# engine is needed) on first run.
#
# Output: a word-level timestamped .vtt file named after the source video.
#
# Notifications are emitted to two channels:
#   - stdout (for Claude or anyone watching the script output)
#   - macOS Notification Center (for the user, via osascript)
#

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Shared helpers (output, notify, parser, HF cache, extract_audio, ...)
# ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# Mac-only: layer macOS Notification Center banners on top of the default
# [notify] stdout marker. Silent failure if osascript is blocked, the
# user hasn't granted notification permission, or the script runs in an
# environment without GUI access.
notify_native() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────
print_help() {
  cat <<EOF
Transcribe a video file to a timestamped VTT subtitle file using local AI.

The engine is chosen from the language:
  - English and 24 other European languages -> Parakeet (parakeet-mlx), fast.
  - Japanese                                -> kotoba-whisper (mlx-whisper).
  - Any other language, or 'auto' fallback  -> whisper-large-v3 (mlx-whisper).

USAGE
  $(basename "$0") <video-file> [output-dir]
  $(basename "$0") -y <video-file> [output-dir]
  $(basename "$0") -y -l ja <video-file> [output-dir]
  $(basename "$0") --check

ARGUMENTS
  video-file   Path to a video or audio file (mp4, mov, mkv, mp3, m4a, etc.)
  output-dir   Directory to save the transcript (default: ./transcripts)

OPTIONS
  -l, --language CODE   Source language (en, ja, fr, de, ...). Default: auto.
                        'auto' detects the language from a 30-second sample,
                        then routes to the right engine.
  --engine NAME         Force the engine: 'parakeet' or 'whisper'. Advanced;
                        normally derived from --language.
  --model REPO          Force a specific HuggingFace model repo. Advanced;
                        overrides the auto-selected model.
  -y, --yes             Skip confirmation prompts when installing missing
                        dependencies. Required when running non-interactively.
  --check               Check dependencies and exit. Installs nothing.
  -h, --help            Show this help.

EXAMPLES
  $(basename "$0") ~/Movies/meeting.mp4
  $(basename "$0") -y -l en ~/Movies/talk.mp4 ~/Documents/transcripts
  $(basename "$0") -y -l ja ~/Movies/anime.mkv
EOF
}

# ──────────────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────────────
ASSUME_YES=0
CHECK_ONLY=0
LANGUAGE="auto"
ENGINE_OVERRIDE=""
MODEL_OVERRIDE=""
POSITIONAL=()

parse_args "$@"

if [ -n "$ENGINE_OVERRIDE" ] && [ "$ENGINE_OVERRIDE" != "parakeet" ] && [ "$ENGINE_OVERRIDE" != "whisper" ]; then
  err "--engine must be 'parakeet' or 'whisper'."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Platform check
# ──────────────────────────────────────────────────────────────────────
if [ "$(uname -s)" != "Darwin" ]; then
  err "This script requires macOS. MLX (the framework used for transcription) is Apple-only."
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  err "This script requires an Apple Silicon Mac (M1/M2/M3/M4 or later)."
  err "MLX does not support Intel Macs. Consider using whisper.cpp instead."
  exit 1
fi

# Make sure common install locations are visible
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# ──────────────────────────────────────────────────────────────────────
# Error trap: notify on any unexpected failure
# ──────────────────────────────────────────────────────────────────────
on_error() {
  local exit_code=$?
  notify "Transcription failed" "Something went wrong. Check terminal output for details."
  exit $exit_code
}
trap on_error ERR

# ──────────────────────────────────────────────────────────────────────
# Dependency installers
# ──────────────────────────────────────────────────────────────────────
ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew is installed."
    return 0
  fi

  warn "Homebrew is not installed. It's needed to install ffmpeg."
  echo "    Homebrew is the standard package manager for macOS (https://brew.sh)."

  if ! ask_yes_no "Install Homebrew now?"; then
    err "Cannot continue without Homebrew."
    exit 1
  fi

  notify "Setup" "Installing Homebrew. This may take a few minutes."
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [ -d /opt/homebrew/bin ]; then
    export PATH="/opt/homebrew/bin:$PATH"
  fi

  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew install did not finish cleanly. Try restarting your terminal and re-running."
    exit 1
  fi
  ok "Homebrew installed."
}

ensure_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg is installed."
    return 0
  fi

  ensure_homebrew

  warn "ffmpeg is not installed. It's needed to extract audio from videos."
  if ! ask_yes_no "Install ffmpeg via Homebrew now?"; then
    err "Cannot continue without ffmpeg."
    exit 1
  fi

  notify "Setup" "Installing ffmpeg."
  info "Installing ffmpeg..."
  brew install ffmpeg
  ok "ffmpeg installed."
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    ok "uv is installed."
    return 0
  fi

  warn "uv is not installed. It's a fast Python package manager needed to run the transcription engines."
  echo "    uv is published by Astral (https://astral.sh/uv)."

  if ! ask_yes_no "Install uv now?"; then
    err "Cannot continue without uv."
    exit 1
  fi

  notify "Setup" "Installing uv."
  info "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh

  if ! command -v uv >/dev/null 2>&1; then
    err "uv install did not finish cleanly. Try restarting your terminal and re-running."
    exit 1
  fi
  ok "uv installed."
}

ensure_mlx_whisper() {
  if command -v mlx_whisper >/dev/null 2>&1; then
    ok "mlx-whisper is installed."
    return 0
  fi

  ensure_uv

  warn "mlx-whisper is not installed. It's the transcription engine for Japanese and other non-European languages."
  if ! ask_yes_no "Install mlx-whisper via uv now?"; then
    err "Cannot continue without mlx-whisper."
    exit 1
  fi

  notify "Setup" "Installing mlx-whisper."
  info "Installing mlx-whisper..."
  uv tool install mlx-whisper

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v mlx_whisper >/dev/null 2>&1; then
    err "mlx-whisper install did not finish cleanly."
    err "Try running this manually: uv tool install mlx-whisper"
    exit 1
  fi
  ok "mlx-whisper installed."
}

ensure_parakeet_mlx() {
  if command -v parakeet-mlx >/dev/null 2>&1; then
    ok "parakeet-mlx is installed."
    return 0
  fi

  ensure_uv

  warn "parakeet-mlx is not installed. It's the fast transcription engine for English and other European languages."
  if ! ask_yes_no "Install parakeet-mlx via uv now?"; then
    err "Cannot continue without parakeet-mlx."
    exit 1
  fi

  notify "Setup" "Installing parakeet-mlx."
  info "Installing parakeet-mlx..."
  uv tool install parakeet-mlx

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v parakeet-mlx >/dev/null 2>&1; then
    err "parakeet-mlx install did not finish cleanly."
    err "Try running this manually: uv tool install parakeet-mlx"
    exit 1
  fi
  ok "parakeet-mlx installed."
}

# ──────────────────────────────────────────────────────────────────────
# Models and routing
# ──────────────────────────────────────────────────────────────────────
# Languages Parakeet TDT v3 supports (ISO 639-1). Anything in this set routes
# to Parakeet; everything else routes to Whisper. Parakeet does its own
# language ID within the set, so we never pass it a --language.
PARAKEET_LANGS="bg cs da de el en es et fi fr hr hu it lt lv mt nl pl pt ro ru sk sl sv uk"

PARAKEET_MODEL_DEFAULT="mlx-community/parakeet-tdt-0.6b-v3"
KOTOBA_MODEL_DEFAULT="kaiinui/kotoba-whisper-v2.0-mlx"
WHISPER_MODEL_DEFAULT="mlx-community/whisper-large-v3-mlx"
PROBE_MODEL="mlx-community/whisper-tiny"

# ENGINE and MODEL are set by route_engine().
ENGINE=""
MODEL=""

# Decide ENGINE and MODEL from a resolved language code ("" => Whisper auto).
# Honors ENGINE_OVERRIDE / MODEL_OVERRIDE if set.
route_engine() {
  local lang="$1"

  if [ -n "$ENGINE_OVERRIDE" ]; then
    ENGINE="$ENGINE_OVERRIDE"
  else
    case " $PARAKEET_LANGS " in
      *" $lang "*) ENGINE="parakeet" ;;
      *)           ENGINE="whisper" ;;
    esac
  fi

  if [ -n "$MODEL_OVERRIDE" ]; then
    MODEL="$MODEL_OVERRIDE"
  elif [ "$ENGINE" = "parakeet" ]; then
    MODEL="$PARAKEET_MODEL_DEFAULT"
  elif [ "$lang" = "ja" ]; then
    MODEL="$KOTOBA_MODEL_DEFAULT"
  else
    MODEL="$WHISPER_MODEL_DEFAULT"
  fi
}

# Detect the spoken language from the first 30s of a wav, using whisper-tiny.
# Prints a language code (e.g. "en", "ja") on success, or nothing on failure.
detect_language() {
  local wav="$1"
  local probe="$WORKDIR/probe.wav"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$wav" -t 30 -ac 1 -ar 16000 -c:a pcm_s16le "$probe" >/dev/null 2>&1 || cp "$wav" "$probe"

  # Predownload progress goes to stderr so it never pollutes the captured code.
  if ! model_cached "$PROBE_MODEL"; then
    predownload_model "$PROBE_MODEL" "$(size_label_for "$PROBE_MODEL")" >&2
  fi

  # mlx_whisper prints its own "Detected language: ..." line to stdout; we tag
  # our answer with a marker and extract only that line, ignoring the chatter.
  local out
  out=$(uv tool run --from mlx-whisper python -c '
import sys, mlx_whisper
try:
    r = mlx_whisper.transcribe(sys.argv[1], path_or_hf_repo=sys.argv[2],
                               language=None, verbose=False)
    print("DETECTED_LANG=" + (r.get("language") or ""))
except Exception:
    print("DETECTED_LANG=")
' "$probe" "$PROBE_MODEL" 2>/dev/null) || out=""

  printf '%s' "$out" | sed -n 's/^DETECTED_LANG=//p' | tail -n1
}

# ──────────────────────────────────────────────────────────────────────
# Check-only mode: report what's installed and exit
# ──────────────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" -eq 1 ]; then
  info "Checking dependencies..."
  missing=0
  for dep in brew ffmpeg uv mlx_whisper; do
    if command -v "$dep" >/dev/null 2>&1; then
      ok "$dep: installed"
    else
      warn "$dep: NOT installed"
      missing=1
    fi
  done

  if command -v parakeet-mlx >/dev/null 2>&1; then
    ok "parakeet-mlx: installed"
  else
    warn "parakeet-mlx: not installed (auto-installs for English/European clips)"
  fi

  for m in "$PARAKEET_MODEL_DEFAULT" "$KOTOBA_MODEL_DEFAULT" "$WHISPER_MODEL_DEFAULT"; do
    if model_cached "$m"; then
      ok "model cached: $m"
    else
      warn "model NOT cached: $m (downloads on first use of that language)"
    fi
  done

  if [ "$missing" -eq 0 ]; then
    ok "Core dependencies present. Ready to transcribe."
    exit 0
  else
    warn "Some dependencies are missing. Run without --check to install them."
    exit 1
  fi
fi

# ──────────────────────────────────────────────────────────────────────
# Validate positional arguments for transcribe mode
# ──────────────────────────────────────────────────────────────────────
if [ "${#POSITIONAL[@]}" -lt 1 ]; then
  err "No video file provided."
  echo "Run with --help for usage."
  exit 1
fi

VIDEO="${POSITIONAL[0]}"
OUTDIR="${POSITIONAL[1]:-./transcripts}"

if [ ! -f "$VIDEO" ]; then
  err "File not found: $VIDEO"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Extract & normalize audio (needed before language detection)
# ──────────────────────────────────────────────────────────────────────
info "Checking dependencies..."
ensure_ffmpeg

mkdir -p "$OUTDIR"

# Stage intermediates in a private temp dir with a clean, single-extension
# basename. macOS mktemp's `-t prefix` does NOT substitute X's — it appends
# .RANDOM to the literal prefix — so a multi-dot wav name confuses the
# engine's output naming. Working out of a fresh dir with `audio.wav`
# sidesteps that and lets us glob for the produced VTT regardless of how the
# engine derives output names.
WORKDIR=$(mktemp -d -t whisper)
trap 'rm -rf "$WORKDIR"' EXIT

TMPWAV="$WORKDIR/audio.wav"

info "Extracting and normalizing audio from: $VIDEO"
extract_audio "$VIDEO" "$TMPWAV"
ok "Audio extracted."

# ──────────────────────────────────────────────────────────────────────
# Resolve language (auto-detect if needed) and route to an engine
# ──────────────────────────────────────────────────────────────────────
if [ "$LANGUAGE" = "auto" ]; then
  ensure_mlx_whisper
  notify "Transcription setup" "Detecting language from a 30-second sample..."
  DETECTED=$(detect_language "$TMPWAV")
  if [ -n "$DETECTED" ]; then
    info "Detected language: $DETECTED"
    LANGUAGE="$DETECTED"
  else
    warn "Language detection failed; falling back to multilingual Whisper (large-v3) with auto-detect."
    LANGUAGE=""
    ENGINE_OVERRIDE="whisper"
  fi
fi

route_engine "$LANGUAGE"
info "Engine: $ENGINE   Model: $MODEL"

if [ "$ENGINE" = "parakeet" ]; then
  ensure_parakeet_mlx
else
  ensure_mlx_whisper
fi

# ──────────────────────────────────────────────────────────────────────
# Pre-download the chosen model if not cached (so progress is visible)
# ──────────────────────────────────────────────────────────────────────
if ! model_cached "$MODEL"; then
  predownload_model "$MODEL" "$(size_label_for "$MODEL")"
else
  ok "Model already cached, skipping download."
fi

# ──────────────────────────────────────────────────────────────────────
# Transcribe
# ──────────────────────────────────────────────────────────────────────
if [ "$ENGINE" = "parakeet" ]; then
  notify "Transcription" "Starting transcription with Parakeet. Usually a few minutes per hour of audio."
  info "Transcribing with parakeet-mlx ($MODEL)..."
  # No --highlight-words: that emits karaoke-style per-word cues (the whole
  # line repeated once per word). We want clean segment-level cues, matching
  # the Whisper path. Word timing is still computed internally for boundaries.
  parakeet-mlx "$TMPWAV" \
    --model "$MODEL" \
    --output-format vtt \
    --output-dir "$WORKDIR" \
    --chunk-duration 120 \
    --overlap-duration 15
else
  notify "Transcription" "Starting transcription with Whisper. Roughly 6-12 minutes per hour of audio."
  info "Transcribing with mlx-whisper ($MODEL)..."
  # Word-splitting on the optional language flag is intentional here.
  # shellcheck disable=SC2086
  mlx_whisper "$TMPWAV" \
    --model "$MODEL" \
    ${LANGUAGE:+--language "$LANGUAGE"} \
    --condition-on-previous-text False \
    --no-speech-threshold 0.3 \
    --output-format vtt \
    --output-dir "$WORKDIR" \
    --word-timestamps True
fi

# ──────────────────────────────────────────────────────────────────────
# Move output to $OUTDIR with the source video's basename
# ──────────────────────────────────────────────────────────────────────
FINAL_PATH=$(finalize_vtt "$VIDEO" "$WORKDIR" "$OUTDIR")
VIDBASE=$(basename "${VIDEO%.*}")

notify "Transcription complete" "Transcript saved: $VIDBASE.vtt"
ok "Done. Transcript saved to: $FINAL_PATH"
