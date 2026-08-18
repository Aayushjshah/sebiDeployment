#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /path/to/benchmark-input [concurrency]" >&2
  echo "example: LIGHTON_ACCESS_TOKEN=... $0 '/Users/tanay.s/XYNE TESTING/Lighon_testing' 1,2,4,8,12,16" >&2
  exit 2
fi

if [[ -z "${LIGHTON_ACCESS_TOKEN:-}" ]]; then
  echo "LIGHTON_ACCESS_TOKEN is required in the environment." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_BIN="${PYTHON:-${ROOT_DIR}/.venv/bin/python}"

INPUT_DIR="$1"
CONCURRENCY="${2:-${LIGHTON_OCR_BENCHMARK_CONCURRENCY:-1,2,4,8,12,16}}"

cd "${ROOT_DIR}"

PYTHONPATH=src "${PYTHON_BIN}" scripts/benchmark_lightonocr.py \
  --input "${INPUT_DIR}" \
  --url "https://apis.airawat.cdac.in/msebisec-lightonocr/v1/chat/completions" \
  --model "lightonai/LightOnOCR-2-1B" \
  --concurrency "${CONCURRENCY}" \
  --fail-fast
