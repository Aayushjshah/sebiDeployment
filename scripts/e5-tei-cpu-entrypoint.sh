#!/usr/bin/env sh
set -eu

if [ "$#" -gt 0 ]; then
  exec text-embeddings-router "$@"
fi

MODEL_PATH="${MODEL_PATH:-/models/multilingual-e5-large-instruct}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-intfloat/multilingual-e5-large-instruct}"
PORT="${PORT:-80}"
TEI_DTYPE="${TEI_DTYPE:-float32}"
TEI_POOLING="${TEI_POOLING:-mean}"
TEI_MAX_CONCURRENT_REQUESTS="${TEI_MAX_CONCURRENT_REQUESTS:-64}"
TEI_MAX_BATCH_TOKENS="${TEI_MAX_BATCH_TOKENS:-8192}"
TEI_MAX_BATCH_REQUESTS="${TEI_MAX_BATCH_REQUESTS:-16}"
TEI_MAX_CLIENT_BATCH_SIZE="${TEI_MAX_CLIENT_BATCH_SIZE:-64}"

set -- \
  --model-id "${MODEL_PATH}" \
  --served-model-name "${SERVED_MODEL_NAME}" \
  --port "${PORT}" \
  --dtype "${TEI_DTYPE}" \
  --pooling "${TEI_POOLING}" \
  --max-concurrent-requests "${TEI_MAX_CONCURRENT_REQUESTS}" \
  --max-batch-tokens "${TEI_MAX_BATCH_TOKENS}" \
  --max-batch-requests "${TEI_MAX_BATCH_REQUESTS}" \
  --max-client-batch-size "${TEI_MAX_CLIENT_BATCH_SIZE}"

if [ -n "${TEI_TOKENIZATION_WORKERS:-}" ]; then
  set -- "$@" --tokenization-workers "${TEI_TOKENIZATION_WORKERS}"
fi

exec text-embeddings-router "$@"
