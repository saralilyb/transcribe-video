#!/usr/bin/env bash
#
# transcribe-video-linux.sh
#
# Linux + NVIDIA CUDA implementation of the transcribe-video skill.
# Invoked by the platform dispatcher at scripts/transcribe-video.sh.
#
# Engine: faster-whisper (CTranslate2) via the whisper-ctranslate2 CLI.
# Single engine covers English, European languages, Japanese (via
# kotoba-tech/kotoba-whisper-v2.0-faster), and the `auto` path — on a
# modern NVIDIA GPU faster-whisper-large-v3 runs ~30-80x realtime, fast
# enough that the Mac-side engine split (Parakeet vs. Whisper) isn't
# needed here. Language detection happens inside the engine when
# --language is omitted, so there's no separate probe phase.
#
# Self-bootstraps all dependencies (ffmpeg via apt/dnf/pacman, uv,
# whisper-ctranslate2) on first run.
#
# Output: a word-level timestamped .vtt file named after the source
# video.
#
# Notifications: [notify] stdout markers for Claude to relay. No native
# desktop banners on Linux/WSL (notify_native is the default no-op from
# common.sh; override here if you want to add notify-send later).
#

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Shared helpers (output, notify, parser, HF cache, extract_audio, ...)
# ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# ──────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────
print_help() {
  cat <<EOF
Transcribe a video file to a timestamped VTT subtitle file using local AI.

Linux/CUDA implementation. One engine for everything:
  - faster-whisper via whisper-ctranslate2, on the local NVIDIA GPU.
  - English / European / unknown -> Systran/faster-whisper-large-v3
  - Japanese (-l ja)             -> kotoba-tech/kotoba-whisper-v2.0-faster

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
                        'auto' lets faster-whisper detect the language
                        internally — no separate probe phase.
  --engine NAME         Accepted for parity with the Mac script, but only
                        'whisper' is meaningful here. 'parakeet' is rejected;
                        the Linux build does not bundle a NeMo Parakeet path.
  --model REPO          Force a specific HuggingFace model repo. Must be a
                        faster-whisper / CTranslate2 model. Advanced.
  -y, --yes             Skip confirmation prompts when installing missing
                        dependencies. Required when running non-interactively.
  --check               Check dependencies and exit. Installs nothing.
  -h, --help            Show this help.

EXAMPLES
  $(basename "$0") ~/Videos/meeting.mp4
  $(basename "$0") -y -l en ~/Videos/talk.mp4 ~/Documents/transcripts
  $(basename "$0") -y -l ja ~/Videos/anime.mkv
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

if [ -n "$ENGINE_OVERRIDE" ] && [ "$ENGINE_OVERRIDE" != "whisper" ]; then
  err "--engine '$ENGINE_OVERRIDE' is not available on Linux."
  err "Only 'whisper' (faster-whisper) is supported here. See SKILL.md."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Platform + GPU check
# ──────────────────────────────────────────────────────────────────────
if [ "$(uname -s)" != "Linux" ]; then
  err "This script requires Linux. Run the dispatcher (transcribe-video.sh) instead."
  exit 1
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
  info "Detected WSL2 environment. CUDA passthrough requires the NVIDIA driver on the Windows host."
  # The WSL2 NVIDIA driver mounts its userspace tools (nvidia-smi and the
  # CUDA shared libraries) at /usr/lib/wsl/lib, which is NOT on the default
  # PATH for non-login shells. Add it so `command -v nvidia-smi` works.
  if [ -d /usr/lib/wsl/lib ]; then
    export PATH="/usr/lib/wsl/lib:$PATH"
  fi
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  err "nvidia-smi not found. This skill requires an NVIDIA GPU with the driver installed."
  err "On WSL2: install the NVIDIA Windows driver on the host; no Linux-side driver needed."
  err "On native Linux: install the proprietary NVIDIA driver for your distro."
  exit 1
fi

if ! nvidia-smi >/dev/null 2>&1; then
  err "nvidia-smi failed. The NVIDIA driver is installed but the GPU isn't reachable."
  err "On WSL2: try restarting WSL ('wsl --shutdown' in Windows) and re-running."
  exit 1
fi

# Make sure common install locations are visible
export PATH="$HOME/.local/bin:$PATH"

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
# Detect the system package manager. Sets PKG_MGR to one of:
#   apt | dnf | pacman   (or empty if none found)
PKG_MGR=""
detect_pkg_mgr() {
  if [ -n "$PKG_MGR" ]; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  fi
}

# Install a package via the detected manager. Uses sudo non-interactively;
# the user is expected to have sudo privileges already (typical on WSL2
# and on personal Linux workstations).
pkg_install() {
  local pkg="$1"
  case "$PKG_MGR" in
    apt)    sudo apt-get update && sudo apt-get install -y "$pkg" ;;
    dnf)    sudo dnf install -y "$pkg" ;;
    pacman) sudo pacman -Sy --noconfirm "$pkg" ;;
    *)
      err "No supported package manager detected (looked for apt-get, dnf, pacman)."
      err "Install '$pkg' manually and re-run this script."
      exit 1
      ;;
  esac
}

ensure_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg is installed."
    return 0
  fi

  detect_pkg_mgr
  if [ -z "$PKG_MGR" ]; then
    err "ffmpeg is not installed and no supported package manager was found."
    err "Install ffmpeg manually (https://ffmpeg.org/download.html) and re-run."
    exit 1
  fi

  warn "ffmpeg is not installed. It's needed to extract audio from videos."
  if ! ask_yes_no "Install ffmpeg via $PKG_MGR now? (will use sudo)"; then
    err "Cannot continue without ffmpeg."
    exit 1
  fi

  notify "Setup" "Installing ffmpeg via $PKG_MGR."
  info "Installing ffmpeg..."
  pkg_install ffmpeg
  ok "ffmpeg installed."
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    ok "uv is installed."
    return 0
  fi

  warn "uv is not installed. It's a fast Python package manager needed to run the transcription engine."
  echo "    uv is published by Astral (https://astral.sh/uv)."

  if ! ask_yes_no "Install uv now?"; then
    err "Cannot continue without uv."
    exit 1
  fi

  notify "Setup" "Installing uv."
  info "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v uv >/dev/null 2>&1; then
    err "uv install did not finish cleanly. Try restarting your shell and re-running."
    exit 1
  fi
  ok "uv installed."
}

# Where uv stores tool venvs. We poke at this directory to detect whether
# the CTranslate2 CUDA runtime shims (nvidia-cublas-cu12, nvidia-cudnn-cu12)
# are present in the whisper-ctranslate2 tool venv. CTranslate2 needs
# libcublas.so.12 and libcudnn.so.* at runtime; the NVIDIA WSL2 driver
# only provides libcuda + libnvidia-ml, NOT cuBLAS or cuDNN. The PyPI
# nvidia-*-cu12 wheels ship those .so files and are the upstream-
# recommended way to satisfy them without installing the full CUDA
# toolkit system-wide.
WHISPER_TOOL_DIR="$HOME/.local/share/uv/tools/whisper-ctranslate2"

# Returns 0 if both nvidia-cublas-cu12 and nvidia-cudnn-cu12 are present
# in the whisper-ctranslate2 tool venv (matched by their .so file).
cuda_shims_present() {
  ls "$WHISPER_TOOL_DIR"/lib/python*/site-packages/nvidia/cublas/lib/libcublas.so.12 \
     >/dev/null 2>&1 \
  && ls "$WHISPER_TOOL_DIR"/lib/python*/site-packages/nvidia/cudnn/lib/libcudnn.so.* \
        >/dev/null 2>&1
}

ensure_whisper_ctranslate2() {
  if command -v whisper-ctranslate2 >/dev/null 2>&1 && cuda_shims_present; then
    ok "whisper-ctranslate2 is installed (with CUDA runtime libs)."
    return 0
  fi

  ensure_uv

  if command -v whisper-ctranslate2 >/dev/null 2>&1; then
    warn "whisper-ctranslate2 is installed but is missing the CUDA runtime libs."
    echo "    CTranslate2 needs libcublas.so.12 / libcudnn.so.* at runtime."
    echo "    Will reinstall with nvidia-cublas-cu12 and nvidia-cudnn-cu12 wheels."
    if ! ask_yes_no "Reinstall whisper-ctranslate2 with bundled CUDA libs now?"; then
      err "Cannot continue without CUDA runtime libs."
      exit 1
    fi
  else
    warn "whisper-ctranslate2 is not installed. It's the faster-whisper-based transcription engine."
    if ! ask_yes_no "Install whisper-ctranslate2 (with bundled CUDA libs) via uv now?"; then
      err "Cannot continue without whisper-ctranslate2."
      exit 1
    fi
  fi

  notify "Setup" "Installing whisper-ctranslate2 with CUDA runtime libs."
  info "Installing whisper-ctranslate2 (+ nvidia-cublas-cu12 + nvidia-cudnn-cu12)..."
  uv tool install --reinstall whisper-ctranslate2 \
    --with nvidia-cublas-cu12 \
    --with nvidia-cudnn-cu12

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v whisper-ctranslate2 >/dev/null 2>&1; then
    err "whisper-ctranslate2 install did not finish cleanly."
    err "Try running this manually:"
    err "  uv tool install --reinstall whisper-ctranslate2 \\"
    err "    --with nvidia-cublas-cu12 --with nvidia-cudnn-cu12"
    exit 1
  fi
  if ! cuda_shims_present; then
    err "CUDA runtime libs are still missing after install. Check the install log above."
    exit 1
  fi
  ok "whisper-ctranslate2 installed."
}

# Prepend the venv's bundled nvidia-*-cu12 lib directories to
# LD_LIBRARY_PATH so the dynamic loader finds libcublas / libcudnn when
# CTranslate2 dlopens them. Idempotent.
export_cuda_ld_path() {
  local libdir nv_lib_dirs=""
  for libdir in "$WHISPER_TOOL_DIR"/lib/python*/site-packages/nvidia/*/lib; do
    [ -d "$libdir" ] && nv_lib_dirs="$libdir:$nv_lib_dirs"
  done
  if [ -n "$nv_lib_dirs" ]; then
    export LD_LIBRARY_PATH="${nv_lib_dirs}${LD_LIBRARY_PATH:-}"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Models
# ──────────────────────────────────────────────────────────────────────
# Single-engine routing on Linux: pick the model from the language alone.
# whisper-ctranslate2 accepts either a built-in Whisper size name
# (tiny|base|small|medium|large|large-v2|large-v3) or a HuggingFace repo
# id that points at a CTranslate2-converted model. We use the latter so
# the model selection is explicit and identical to what `hf download`
# pre-fetches.
WHISPER_MODEL_DEFAULT="Systran/faster-whisper-large-v3"
KOTOBA_MODEL_DEFAULT="kotoba-tech/kotoba-whisper-v2.0-faster"

MODEL=""

resolve_model() {
  local lang="$1"
  if [ -n "$MODEL_OVERRIDE" ]; then
    MODEL="$MODEL_OVERRIDE"
  elif [ "$lang" = "ja" ]; then
    MODEL="$KOTOBA_MODEL_DEFAULT"
  else
    MODEL="$WHISPER_MODEL_DEFAULT"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Check-only mode: report what's installed and exit
# ──────────────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" -eq 1 ]; then
  info "Checking dependencies..."
  missing=0

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi: GPU reachable"
  else
    warn "nvidia-smi: NOT working (script will refuse to run)"
    missing=1
  fi

  for dep in ffmpeg uv whisper-ctranslate2; do
    if command -v "$dep" >/dev/null 2>&1; then
      ok "$dep: installed"
    else
      warn "$dep: NOT installed"
      missing=1
    fi
  done

  if command -v whisper-ctranslate2 >/dev/null 2>&1; then
    if cuda_shims_present; then
      ok "CUDA runtime libs (cublas/cudnn): bundled in whisper-ctranslate2 venv"
    else
      warn "CUDA runtime libs (cublas/cudnn): NOT bundled (CTranslate2 will fail at transcribe time)"
      missing=1
    fi
  fi

  for m in "$WHISPER_MODEL_DEFAULT" "$KOTOBA_MODEL_DEFAULT"; do
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
# Extract & normalize audio
# ──────────────────────────────────────────────────────────────────────
info "Checking dependencies..."
ensure_ffmpeg

mkdir -p "$OUTDIR"

# Stage intermediates in a private temp dir with a clean basename so the
# engine's output naming stays predictable.
WORKDIR=$(mktemp -d -t whisper.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

TMPWAV="$WORKDIR/audio.wav"

info "Extracting and normalizing audio from: $VIDEO"
extract_audio "$VIDEO" "$TMPWAV"
ok "Audio extracted."

# ──────────────────────────────────────────────────────────────────────
# Resolve model and ensure engine is installed
# ──────────────────────────────────────────────────────────────────────
# `auto` collapses to letting faster-whisper detect language itself by
# passing no --language flag, so we don't need a separate probe pass.
if [ "$LANGUAGE" = "auto" ]; then
  LANGUAGE=""
fi

resolve_model "$LANGUAGE"
info "Engine: whisper-ctranslate2   Model: $MODEL"

ensure_whisper_ctranslate2

# ──────────────────────────────────────────────────────────────────────
# Pre-download the chosen model if not cached (so progress is visible)
# ──────────────────────────────────────────────────────────────────────
if ! model_cached "$MODEL"; then
  predownload_model "$MODEL" "$(size_label_for "$MODEL")"
else
  ok "Model already cached, skipping download."
fi

# ──────────────────────────────────────────────────────────────────────
# Resolve the local snapshot path for the downloaded model
# ──────────────────────────────────────────────────────────────────────
# whisper-ctranslate2's --model flag only accepts a fixed enum of built-in
# Whisper size names (tiny, large-v3, large-v3-turbo, ...). It does NOT
# accept arbitrary HuggingFace repo ids. For our case — Systran's CT2-
# converted large-v3, and kotoba-tech's CT2-converted kotoba-whisper —
# we need to point at the on-disk snapshot directory via --model_directory.
# HF stores snapshots at:
#   ~/.cache/huggingface/hub/models--<owner>--<name>/snapshots/<commit-sha>/
MODEL_SNAPSHOT_BASE="$HOME/.cache/huggingface/hub/models--${MODEL//\//--}/snapshots"
# shellcheck disable=SC2012
MODEL_DIR=$(ls -1dt "$MODEL_SNAPSHOT_BASE"/*/ 2>/dev/null | head -1)
MODEL_DIR="${MODEL_DIR%/}"
if [ -z "$MODEL_DIR" ] || [ ! -d "$MODEL_DIR" ]; then
  err "Could not locate downloaded snapshot for model: $MODEL"
  err "Expected a directory under: $MODEL_SNAPSHOT_BASE"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Transcribe
# ──────────────────────────────────────────────────────────────────────
notify "Transcription" "Starting transcription with faster-whisper on CUDA. Usually well under realtime on a modern GPU."
info "Transcribing with whisper-ctranslate2 ($MODEL)..."
info "Using local snapshot: $MODEL_DIR"

# Make the bundled CUDA libs discoverable to CTranslate2's dlopen.
export_cuda_ld_path

# Word-splitting on the optional language flag is intentional here.
# shellcheck disable=SC2086
whisper-ctranslate2 "$TMPWAV" \
  --model_directory "$MODEL_DIR" \
  --device cuda \
  --compute_type float16 \
  --output_format vtt \
  --output_dir "$WORKDIR" \
  --word_timestamps True \
  --condition_on_previous_text False \
  --no_speech_threshold 0.3 \
  ${LANGUAGE:+--language "$LANGUAGE"}

# ──────────────────────────────────────────────────────────────────────
# Move output to $OUTDIR with the source video's basename
# ──────────────────────────────────────────────────────────────────────
FINAL_PATH=$(finalize_vtt "$VIDEO" "$WORKDIR" "$OUTDIR")
VIDBASE=$(basename "${VIDEO%.*}")

notify "Transcription complete" "Transcript saved: $VIDBASE.vtt"
ok "Done. Transcript saved to: $FINAL_PATH"
