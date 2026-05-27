#!/usr/bin/env bash
#
# transcribe-video.sh
#
# Thin dispatcher: detects the host platform and execs the right
# per-platform implementation with the original argv. The two
# implementations diverge entirely on the engine layer:
#
#   - Darwin (Apple Silicon): MLX engines — parakeet-mlx, mlx-whisper
#   - Linux (NVIDIA CUDA):    faster-whisper via whisper-ctranslate2
#
# Public CLI is stable across platforms. See --help for usage.
#
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

case "$(uname -s)" in
  Darwin)
    exec "$DIR/transcribe-video-darwin.sh" "$@"
    ;;
  Linux)
    exec "$DIR/transcribe-video-linux.sh" "$@"
    ;;
  *)
    echo "Unsupported OS: $(uname -s)." >&2
    echo "This skill runs on Apple Silicon macOS or Linux with an NVIDIA GPU." >&2
    exit 1
    ;;
esac
