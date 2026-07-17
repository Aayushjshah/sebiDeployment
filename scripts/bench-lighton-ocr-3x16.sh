#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
PAGE_INDEX="${2:-0}"

if [ -z "${INPUT_PATH}" ] || [ ! -f "${INPUT_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf-or-image [zero_based_page_index]" >&2
  echo "env: MEASURED_ROUNDS=5 WARMUP_ROUNDS=1 CPUSET_START=0 KEEP_CONTAINERS=false" >&2
  exit 1
fi

INPUT_PATH="$(cd "$(dirname "${INPUT_PATH}")" && pwd)/$(basename "${INPUT_PATH}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

IMAGE="${IMAGE:-lighton-ocr-vllm-cpu:sebi-20260714}"
CPUSET_START="${CPUSET_START:-0}"
WARMUP_ROUNDS="${WARMUP_ROUNDS:-1}"
MEASURED_ROUNDS="${MEASURED_ROUNDS:-5}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-false}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_DIR}/benchmark-results}"
RESULT_DIR="${TMP_DIR:-${RESULTS_ROOT}/lighton-ocr-3x16-${RUN_ID}}"

mkdir -p "${RESULT_DIR}"

{
  echo "run_id=${RUN_ID}"
  echo "started_at=$(date -Is)"
  echo "input_path=${INPUT_PATH}"
  echo "page_index=${PAGE_INDEX}"
  echo "image=${IMAGE}"
  echo "instance_count=3"
  echo "cores_per_instance=16"
  echo "cpu_sets=${CPUSET_START}-$((CPUSET_START + 15)),$((CPUSET_START + 16))-$((CPUSET_START + 31)),$((CPUSET_START + 32))-$((CPUSET_START + 47))"
  echo "warmup_rounds=${WARMUP_ROUNDS}"
  echo "measured_rounds=${MEASURED_ROUNDS}"
  echo "measured_requests=$((MEASURED_ROUNDS * 3))"
} > "${RESULT_DIR}/run-config.txt"

echo "Running three LightOnOCR containers with sixteen dedicated cores each."
echo "Each round sends one request to all three containers simultaneously."
echo "Results: ${RESULT_DIR}"

IMAGE="${IMAGE}" \
INSTANCE_COUNTS="3" \
CORES_PER_INSTANCE="16" \
CPUSET_START="${CPUSET_START}" \
WARMUP_ROUNDS="${WARMUP_ROUNDS}" \
MEASURED_ROUNDS="${MEASURED_ROUNDS}" \
KEEP_CONTAINERS="${KEEP_CONTAINERS}" \
TMP_DIR="${RESULT_DIR}" \
./scripts/bench-lighton-ocr-multi-instance.sh "${INPUT_PATH}" "${PAGE_INDEX}" \
  2>&1 | tee "${RESULT_DIR}/console.log"

echo "finished_at=$(date -Is)" >> "${RESULT_DIR}/run-config.txt"

echo ""
echo "Recorded results:"
echo "  Summary: ${RESULT_DIR}/summary.txt"
echo "  Requests: ${RESULT_DIR}/requests.csv"
echo "  Host metrics: ${RESULT_DIR}/host_metrics.csv"
echo "  Container metrics: ${RESULT_DIR}/docker_stats.jsonl"
echo "  Console log: ${RESULT_DIR}/console.log"
