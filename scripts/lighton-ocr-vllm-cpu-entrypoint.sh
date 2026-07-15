#!/usr/bin/env bash
set -euo pipefail

MODEL_PATH="${MODEL_PATH:-/models/lighton-ocr}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-lightonai/LightOnOCR-2-1B-bbox}"
VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_DTYPE="${VLLM_DTYPE:-bfloat16}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
LIMIT_MM_PER_PROMPT="${LIMIT_MM_PER_PROMPT:-{\"image\":1}}"

if [ ! -d "${MODEL_PATH}" ]; then
  echo "Model path does not exist: ${MODEL_PATH}" >&2
  exit 1
fi

exec vllm serve "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --host "${VLLM_HOST}" \
  --port "${VLLM_PORT}" \
  --dtype "${VLLM_DTYPE}" \
  --max-model-len "${MAX_MODEL_LEN}" \
  --max-num-seqs "${MAX_NUM_SEQS}" \
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}" \
  --limit-mm-per-prompt "${LIMIT_MM_PER_PROMPT}" \
  --mm-processor-cache-gb 0 \
  --no-enable-prefix-caching \
  "$@"
