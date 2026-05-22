#!/usr/bin/env bash
#
# transcribe-video.sh
#
# Extracts audio from a video file and transcribes it locally on Apple
# Silicon. Two engines, picked by language:
#
#   - parakeet-mlx  (NVIDIA Parakeet TDT v3) for English and 24 other
#     European languages. Much faster than Whisper.
#   - mlx-whisper   for Japanese (kotoba-whisper) and every other language,
#     and for `auto` fallback.
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
# Usage:
#   transcribe-video.sh <video-file> [output-dir]
#   transcribe-video.sh -y <video-file> [output-dir]      # auto-install deps
#   transcribe-video.sh -y -l ja <video-file>             # force Japanese
#   transcribe-video.sh --check                           # report deps only
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

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=1 ;;
    --check)     CHECK_ONLY=1 ;;
    -l|--language)
      shift
      [ $# -gt 0 ] || { err "--language requires a value (e.g. en, ja, fr, auto)."; exit 1; }
      LANGUAGE="$1"
      ;;
    --language=*) LANGUAGE="${1#*=}" ;;
    --engine)
      shift
      [ $# -gt 0 ] || { err "--engine requires a value (parakeet or whisper)."; exit 1; }
      ENGINE_OVERRIDE="$1"
      ;;
    --engine=*)  ENGINE_OVERRIDE="${1#*=}" ;;
    --model)
      shift
      [ $# -gt 0 ] || { err "--model requires a value (a HuggingFace repo id)."; exit 1; }
      MODEL_OVERRIDE="$1"
      ;;
    --model=*)   MODEL_OVERRIDE="${1#*=}" ;;
    -h|--help)   print_help; exit 0 ;;
    -*)          err "Unknown option: $1"; echo "Run with --help for usage."; exit 1 ;;
    *)           POSITIONAL+=("$1") ;;
  esac
  shift
done

# Normalize language to lowercase so routing matches detection output.
LANGUAGE=$(printf '%s' "$LANGUAGE" | tr '[:upper:]' '[:lower:]')

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

# Rough download size for a model repo, for user-facing messages.
size_label_for() {
  case "$1" in
    *parakeet*) printf '~2.5 GB' ;;
    *kotoba*)   printf '~1.5 GB' ;;
    *large-v3*) printf '~1.6 GB' ;;
    *tiny*)     printf '~75 MB'  ;;
    *)          printf 'a model' ;;
  esac
}

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

# ──────────────────────────────────────────────────────────────────────
# Model cache helpers
# ──────────────────────────────────────────────────────────────────────
# Returns 0 if the model is already in the HuggingFace cache.
# HF caches models at ~/.cache/huggingface/hub/models--<owner>--<name>/
model_cached() {
  local model="$1"
  local cache_dir="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  [ -d "$cache_dir" ] && \
    [ -d "$cache_dir/snapshots" ] && \
    [ -n "$(ls -A "$cache_dir/snapshots" 2>/dev/null)" ]
}

# Pre-download a model with visible progress, separate from transcription.
# Without this, the engine downloads the model silently on first run and the
# user sees no progress for several minutes.
predownload_model() {
  local model="$1"
  local size="$2"
  notify "Transcription setup" "Downloading speech recognition model ($size). One-time download, may take several minutes."
  info "Pre-downloading model so progress is visible..."
  echo "    Model: $model"
  echo "    Destination: ~/.cache/huggingface/hub/"
  echo

  # Use uvx to run the HuggingFace CLI ephemerally. `hf` is the current CLI
  # (the old `huggingface-cli` is deprecated and no longer downloads). This
  # shows tqdm progress bars per file; falls back to a python snippet if it fails.
  if ! uvx --from huggingface_hub hf download "$model"; then
    warn "hf download failed. Falling back to python snapshot_download..."
    uv run --with huggingface_hub python -c "
from huggingface_hub import snapshot_download
snapshot_download('$model')
"
  fi

  notify "Transcription setup" "Model download complete."
  ok "Model ready."
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
ffmpeg -hide_banner -loglevel error -y \
  -i "$VIDEO" \
  -vn -ac 1 -ar 16000 \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a pcm_s16le \
  "$TMPWAV"
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
VIDBASE=$(basename "${VIDEO%.*}")
FINAL_PATH="$OUTDIR/$VIDBASE.vtt"

shopt -s nullglob
produced=("$WORKDIR"/*.vtt)
shopt -u nullglob
if [ ${#produced[@]} -eq 0 ]; then
  err "$ENGINE did not produce a VTT file in $WORKDIR."
  exit 1
fi
mv "${produced[0]}" "$FINAL_PATH"

notify "Transcription complete" "Transcript saved: $VIDBASE.vtt"
ok "Done. Transcript saved to: $FINAL_PATH"
