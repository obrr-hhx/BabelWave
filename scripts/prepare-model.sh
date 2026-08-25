#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_WORK_DIR="$PROJECT_DIR/.model-work"
VENV_DIR="$MODEL_WORK_DIR/venv"
HF_DIR="$MODEL_WORK_DIR/Qwen3-ASR-0.6B"
OUTPUT_MODEL="$MODEL_WORK_DIR/qwen3-asr-0.6b-q8_0.gguf"
INSTALL_DIR="$HOME/Library/Application Support/BabelWave/models"
PYTHON_BIN="${BABELWAVE_PYTHON:-python3}"

mkdir -p "$MODEL_WORK_DIR"
"$PYTHON_BIN" -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install -U pip
"$VENV_DIR/bin/pip" install \
    -r "$PROJECT_DIR/third_party/qwen3-asr.cpp/scripts/requirements.txt" \
    huggingface_hub \
    gguf
"$VENV_DIR/bin/hf" download Qwen/Qwen3-ASR-0.6B --local-dir "$HF_DIR"

"$VENV_DIR/bin/python" "$PROJECT_DIR/third_party/qwen3-asr.cpp/scripts/convert_hf_to_gguf.py" \
    --input "$HF_DIR" \
    --output "$OUTPUT_MODEL" \
    --type q8_0

mkdir -p "$INSTALL_DIR"
cp "$OUTPUT_MODEL" "$INSTALL_DIR/qwen3-asr-0.6b-q8_0.gguf"
echo "Installed model at $INSTALL_DIR/qwen3-asr-0.6b-q8_0.gguf"
