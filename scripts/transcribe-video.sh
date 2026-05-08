#!/usr/bin/env bash
#
# transcribe-video.sh
#
# Extracts audio from a video file and transcribes it locally using
# mlx-whisper on Apple Silicon. Self-bootstraps all dependencies
# (Homebrew, ffmpeg, uv, mlx-whisper) on first run.
#
# Output: a word-level timestamped .vtt file alongside any other
# requested formats, named after the source video.
#
# Notifications are emitted to two channels:
#   - stdout (for Claude or anyone watching the script output)
#   - macOS Notification Center (for the user, via osascript)
#
# Usage:
#   transcribe-video.sh <video-file> [output-dir]
#   transcribe-video.sh -y <video-file> [output-dir]   # auto-install deps
#   transcribe-video.sh --check                        # report deps only
#

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Output helpers
# ──────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
else
  BLUE=''; GREEN=''; YELLOW=''; RED=''; BOLD=''; RESET=''
fi

info()  { printf "${BLUE}==>${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
err()   { printf "${RED}[error]${RESET} %s\n" "$*" >&2; }

# Dual-channel notification: stdout (Claude) + macOS Notification Center (user).
# The [notify] tag on stdout makes it easy for Claude to identify and relay
# these milestones to the user conversationally, even if the osascript
# notification is missed or notification permission was denied.
notify() {
  local title="$1"
  local message="$2"
  printf "${BOLD}${BLUE}[notify]${RESET} %s: %s\n" "$title" "$message"
  # Best-effort native notification. Silent failure if osascript is blocked,
  # the user has not granted notification permission, or the script runs in
  # an environment without GUI access.
  osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────────────────────────────
ASSUME_YES=0
CHECK_ONLY=0
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=1 ;;
    --check)     CHECK_ONLY=1 ;;
    -h|--help)
      cat <<EOF
Transcribe a video file to a timestamped VTT subtitle file using local AI.

USAGE
  $(basename "$0") <video-file> [output-dir]
  $(basename "$0") -y <video-file> [output-dir]
  $(basename "$0") --check

ARGUMENTS
  video-file   Path to a video or audio file (mp4, mov, mkv, mp3, m4a, etc.)
  output-dir   Directory to save the transcript (default: ./transcripts)

OPTIONS
  -y, --yes    Skip confirmation prompts when installing missing dependencies.
               Required when running non-interactively (e.g. via Claude).
  --check      Check dependencies and exit. Prints status, installs nothing.
  -h, --help   Show this help.

EXAMPLES
  $(basename "$0") ~/Movies/meeting.mp4
  $(basename "$0") -y ~/Movies/meeting.mp4 ~/Documents/transcripts
EOF
      exit 0
      ;;
    *)           POSITIONAL+=("$arg") ;;
  esac
done

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
# Consent helper
# ──────────────────────────────────────────────────────────────────────
ask_yes_no() {
  local prompt="$1"

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    err "Need to install: $prompt"
    err "Running non-interactively without -y/--yes flag. Re-run with -y to allow installs."
    exit 1
  fi

  local response
  while true; do
    printf "%s [y/n]: " "$prompt"
    read -r response
    case "$response" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

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

  warn "uv is not installed. It's a fast Python package manager needed to run mlx-whisper."
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

  warn "mlx-whisper is not installed."
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

# ──────────────────────────────────────────────────────────────────────
# Model cache helpers
# ──────────────────────────────────────────────────────────────────────
MODEL="mlx-community/whisper-large-v3-mlx"

# Returns 0 if the model is already in the HuggingFace cache.
# HF caches models at ~/.cache/huggingface/hub/models--<owner>--<name>/
model_cached() {
  local model="$1"
  local cache_dir="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  [ -d "$cache_dir" ] && \
    [ -d "$cache_dir/snapshots" ] && \
    [ -n "$(ls -A "$cache_dir/snapshots" 2>/dev/null)" ]
}

# Pre-download the model with visible progress, separate from the
# transcription step. Without this, mlx_whisper downloads the model
# silently on first run and the user sees no progress for several minutes.
predownload_model() {
  local model="$1"
  notify "Transcription setup" "Downloading speech recognition model (~1.6 GB). One-time download, may take several minutes."
  info "Pre-downloading model so progress is visible..."
  echo "    Model: $model"
  echo "    Destination: ~/.cache/huggingface/hub/"
  echo

  # Use uvx to run huggingface-cli ephemerally. This shows tqdm progress bars
  # for each file. Falls back to a python snippet if huggingface-cli is unavailable.
  if ! uvx --from huggingface_hub huggingface-cli download "$model"; then
    warn "huggingface-cli download failed. Falling back to python snapshot_download..."
    uv tool run --from mlx-whisper python -c "
from huggingface_hub import snapshot_download
snapshot_download('$model')
"
  fi

  notify "Transcription setup" "Model download complete."
  ok "Model ready."
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

  if model_cached "$MODEL"; then
    ok "model: cached ($MODEL)"
  else
    warn "model: NOT cached ($MODEL) — first transcription will download ~1.6 GB"
  fi

  if [ "$missing" -eq 0 ]; then
    ok "All dependencies present. Ready to transcribe."
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
# Install dependencies as needed
# ──────────────────────────────────────────────────────────────────────
info "Checking dependencies..."
ensure_ffmpeg
ensure_mlx_whisper

# ──────────────────────────────────────────────────────────────────────
# Pre-download model if not cached (so progress is visible to user/Claude)
# ──────────────────────────────────────────────────────────────────────
if ! model_cached "$MODEL"; then
  predownload_model "$MODEL"
else
  ok "Model already cached, skipping download."
fi

# ──────────────────────────────────────────────────────────────────────
# Extract & normalize audio
# ──────────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR"

# Stage intermediates in a private temp dir with a clean, single-extension
# basename. macOS mktemp's `-t prefix` does NOT substitute X's — it appends
# .RANDOM to the literal prefix — so a multi-dot wav name confuses
# mlx_whisper's output naming. Working out of a fresh dir with `audio.wav`
# sidesteps that and lets us glob for the produced VTT regardless of how
# mlx_whisper derives output names.
WORKDIR=$(mktemp -d -t whisper)
trap 'rm -rf "$WORKDIR"' EXIT

TMPWAV="$WORKDIR/audio.wav"

info "Extracting and normalizing audio from: $VIDEO"
ffmpeg -hide_banner -loglevel error -y \
  -i "$VIDEO" \
  -vn -ac 1 -ar 16000 \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a pcm_s16le \
  "$TMPWAV"
ok "Audio extracted."

# ──────────────────────────────────────────────────────────────────────
# Transcribe
# ──────────────────────────────────────────────────────────────────────
notify "Transcription" "Starting transcription. Roughly 6-12 minutes per hour of audio."
info "Transcribing with mlx-whisper (large-v3)..."

mlx_whisper "$TMPWAV" \
  --model "$MODEL" \
  --language en \
  --condition-on-previous-text False \
  --no-speech-threshold 0.3 \
  --output-format vtt \
  --output-dir "$WORKDIR" \
  --word-timestamps True

# ──────────────────────────────────────────────────────────────────────
# Move output to $OUTDIR with the source video's basename
# ──────────────────────────────────────────────────────────────────────
VIDBASE=$(basename "${VIDEO%.*}")
FINAL_PATH="$OUTDIR/$VIDBASE.vtt"

shopt -s nullglob
produced=("$WORKDIR"/*.vtt)
shopt -u nullglob
if [ ${#produced[@]} -eq 0 ]; then
  err "mlx_whisper did not produce a VTT file in $WORKDIR."
  exit 1
fi
mv "${produced[0]}" "$FINAL_PATH"

notify "Transcription complete" "Transcript saved: $VIDBASE.vtt"
ok "Done. Transcript saved to: $FINAL_PATH"
