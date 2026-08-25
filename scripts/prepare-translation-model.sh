#!/bin/bash
set -euo pipefail

MODEL_URL="https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf"
MODEL_SHA256="061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"
INSTALL_DIR="$HOME/Library/Application Support/BabelWave/models"
MODEL_PATH="$INSTALL_DIR/qwen3-1.7b-q8_0.gguf"
PART_PATH="$MODEL_PATH.part"

mkdir -p "$INSTALL_DIR"
curl --fail --location --continue-at - --output "$PART_PATH" "$MODEL_URL"

ACTUAL_SHA256="$(shasum -a 256 "$PART_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$MODEL_SHA256" ]]; then
    echo "SHA-256 mismatch: expected $MODEL_SHA256, got $ACTUAL_SHA256" >&2
    exit 1
fi

mv "$PART_PATH" "$MODEL_PATH"
echo "Installed translation model at $MODEL_PATH"
