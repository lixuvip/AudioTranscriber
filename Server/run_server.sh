#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew path is loaded for uvicorn and transcribe.py (ffmpeg, python3.11)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export http_proxy="${http_proxy:-http://127.0.0.1:7897}"
export https_proxy="${https_proxy:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,hf-mirror.com}"
export no_proxy="${no_proxy:-localhost,127.0.0.1,hf-mirror.com}"

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SERVER_DIR"

# Create log directories if they don't exist
mkdir -p "$HOME/.cache/VoiceScribeServer/logs"

# Load environment variables if .env exists
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

# Detect best available python
if [[ -f "/opt/homebrew/bin/python3.11" ]]; then
  PYTHON_EXEC="/opt/homebrew/bin/python3.11"
elif which python3.11 >/dev/null 2>&1; then
  PYTHON_EXEC="python3.11"
else
  PYTHON_EXEC="python3"
fi

# Set default token if not set
export VOICESCRIBE_TOKEN="${VOICESCRIBE_TOKEN:-default-voicescribe-token}"
export VOICESCRIBE_DATA_ROOT="${VOICESCRIBE_DATA_ROOT:-$HOME/.cache/VoiceScribeServer}"
export VOICESCRIBE_SCRIPTS_DIR="${VOICESCRIBE_SCRIPTS_DIR:-$SERVER_DIR/../Scripts}"

# Run uvicorn on port 8766 (to not conflict with MusicMaker-AI on 8765)
echo "==> Starting VoiceScribeServer on port 8766 using $PYTHON_EXEC..."
if [[ -d .venv ]]; then
  .venv/bin/uvicorn voicescribe_server.app:app --host 0.0.0.0 --port 8766
else
  # Fallback to system or homebrew python
  "$PYTHON_EXEC" -m uvicorn voicescribe_server.app:app --host 0.0.0.0 --port 8766
fi
