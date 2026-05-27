# shellcheck shell=bash
#
# common.sh
#
# Platform-agnostic helpers shared between transcribe-video-darwin.sh
# and transcribe-video-linux.sh. Source this file from a per-platform
# script; do not run it directly.
#
# What's in here:
#   - Color/output helpers (info/ok/warn/err)
#   - notify() that emits [notify] stdout markers; native banners are
#     opt-in via the notify_native() hook (default: no-op)
#   - parse_args() — the CLI parser, populating global variables
#   - ask_yes_no() consent helper
#   - HuggingFace cache helpers (model_cached, predownload_model)
#   - extract_audio() — ffmpeg + loudnorm pipeline
#   - finalize_vtt() — move produced VTT to the named output path
#   - size_label_for() — rough download size labels for [notify] text
#

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

# ──────────────────────────────────────────────────────────────────────
# Notifications
# ──────────────────────────────────────────────────────────────────────
# notify_native is the platform-specific hook. The default is a no-op so
# Linux gets [notify] stdout only. The Darwin script redefines it to call
# osascript. To add notify-send on Linux later, override it the same way.
notify_native() { :; }

# Dual-channel notification: stdout (Claude relays this) + optional native
# banner. The [notify] tag on stdout makes it easy for Claude to identify
# and relay these milestones to the user conversationally.
notify() {
  local title="$1"
  local message="$2"
  printf "${BOLD}${BLUE}[notify]${RESET} %s: %s\n" "$title" "$message"
  notify_native "$title" "$message" || true
}

# ──────────────────────────────────────────────────────────────────────
# Consent helper
# ──────────────────────────────────────────────────────────────────────
# Returns 0 (yes) / 1 (no). Honors $ASSUME_YES. Refuses to silently
# proceed when stdin isn't a TTY and -y wasn't passed.
ask_yes_no() {
  local prompt="$1"

  if [ "${ASSUME_YES:-0}" -eq 1 ]; then
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
# Argument parsing
# ──────────────────────────────────────────────────────────────────────
# Populates the following globals (caller declares defaults before calling):
#   ASSUME_YES, CHECK_ONLY, LANGUAGE, ENGINE_OVERRIDE, MODEL_OVERRIDE,
#   POSITIONAL (array)
#
# Caller must define print_help() before calling parse_args, because the
# accepted --engine values and the help text differ between platforms.
parse_args() {
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
        [ $# -gt 0 ] || { err "--engine requires a value."; exit 1; }
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
}

# ──────────────────────────────────────────────────────────────────────
# HuggingFace cache helpers
# ──────────────────────────────────────────────────────────────────────
# HF caches models at ~/.cache/huggingface/hub/models--<owner>--<name>/
# Returns 0 if the model is already in the cache.
model_cached() {
  local model="$1"
  local cache_dir="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  [ -d "$cache_dir" ] && \
    [ -d "$cache_dir/snapshots" ] && \
    [ -n "$(ls -A "$cache_dir/snapshots" 2>/dev/null)" ]
}

# Pre-download a model with visible progress, separate from transcription.
# Without this, the engine downloads the model silently on first run and
# the user sees no progress for several minutes.
predownload_model() {
  local model="$1"
  local size="$2"
  notify "Transcription setup" "Downloading speech recognition model ($size). One-time download, may take several minutes."
  info "Pre-downloading model so progress is visible..."
  echo "    Model: $model"
  echo "    Destination: ~/.cache/huggingface/hub/"
  echo

  # `hf` is the current HuggingFace CLI; the old `huggingface-cli` is
  # deprecated and no longer downloads. Shows tqdm progress bars per file.
  # Fall back to a python snippet if the CLI fails for any reason.
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

# Rough download size for a model repo, for user-facing messages. Patterns
# cover both MLX-converted and CT2-converted variants of the same upstream.
size_label_for() {
  case "$1" in
    *parakeet*)            printf '~2.5 GB' ;;
    *kotoba*)              printf '~1.5 GB' ;;
    *large-v3*)            printf '~1.6 GB' ;;
    *tiny*)                printf '~75 MB'  ;;
    *)                     printf 'a model' ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────
# Audio extraction
# ──────────────────────────────────────────────────────────────────────
# Extract mono 16 kHz PCM with loudnorm applied. Output goes to $2.
# loudnorm to broadcast standard (-16 LUFS) helps both engines and
# specifically suppresses Whisper's [Music]-collapse failure mode.
extract_audio() {
  local video="$1"
  local out_wav="$2"
  ffmpeg -hide_banner -loglevel error -y \
    -i "$video" \
    -vn -ac 1 -ar 16000 \
    -af "loudnorm=I=-16:TP=-1.5:LRA=11" \
    -c:a pcm_s16le \
    "$out_wav"
}

# ──────────────────────────────────────────────────────────────────────
# VTT finalization
# ──────────────────────────────────────────────────────────────────────
# Move the engine's produced .vtt out of $workdir into
# "$outdir/<video-basename>.vtt". Prints the final path. Errors out if
# the engine didn't produce a VTT.
finalize_vtt() {
  local video="$1"
  local workdir="$2"
  local outdir="$3"

  local vidbase
  vidbase=$(basename "${video%.*}")
  local final_path="$outdir/$vidbase.vtt"

  shopt -s nullglob
  local produced=("$workdir"/*.vtt)
  shopt -u nullglob
  if [ ${#produced[@]} -eq 0 ]; then
    err "Engine did not produce a VTT file in $workdir."
    return 1
  fi
  mv "${produced[0]}" "$final_path"
  printf '%s' "$final_path"
}
