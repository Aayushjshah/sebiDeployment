#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
PAGE_INDEX="${2:-0}"

CONTAINER="${CONTAINER:-lighton-ocr-vllm-cpu}"
CPUS="${CPUS:-32}"
CPUSET="${CPUSET:-}"
RESTORE_CPU_LIMIT="${RESTORE_CPU_LIMIT:-true}"

if [ -z "${INPUT_PATH}" ] || [ ! -f "${INPUT_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf-or-image [zero_based_page_index]" >&2
  echo "env: CPUS=32 CPUSET=0-31 CONTAINER=lighton-ocr-vllm-cpu REQUESTS=3 CONCURRENCY=1" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "container not found: ${CONTAINER}" >&2
  exit 1
fi

if [ -z "${CPUSET}" ]; then
  if ! [[ "${CPUS}" =~ ^[0-9]+$ ]] || [ "${CPUS}" -lt 1 ]; then
    echo "CPUS must be a positive integer when CPUSET is not provided" >&2
    exit 1
  fi
  CPUSET="0-$((CPUS - 1))"
fi

orig_cpuset="$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "${CONTAINER}")"
orig_nanocpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${CONTAINER}")"
orig_cpus=""
if [ "${orig_nanocpus}" != "0" ]; then
  orig_cpus="$(python3 - "${orig_nanocpus}" <<'PY'
import sys
print(float(sys.argv[1]) / 1_000_000_000)
PY
)"
fi

restore_limits() {
  if [ "${RESTORE_CPU_LIMIT}" != "true" ]; then
    return 0
  fi

  echo "restoring_cpu_limits container=${CONTAINER} cpuset=${orig_cpuset:-<none>} cpus=${orig_cpus:-<none>}" >&2
  args=()
  if [ -n "${orig_cpuset}" ]; then
    args+=(--cpuset-cpus "${orig_cpuset}")
  else
    args+=(--cpuset-cpus "")
  fi
  if [ -n "${orig_cpus}" ]; then
    args+=(--cpus "${orig_cpus}")
  else
    args+=(--cpus "0")
  fi
  docker update "${args[@]}" "${CONTAINER}" >/dev/null
}

trap restore_limits EXIT

echo "original_cpu_limits container=${CONTAINER} cpuset=${orig_cpuset:-<none>} nanocpus=${orig_nanocpus}"
echo "applying_cpu_limits container=${CONTAINER} cpuset=${CPUSET} cpus=${CPUS}"
docker update --cpuset-cpus "${CPUSET}" --cpus "${CPUS}" "${CONTAINER}" >/dev/null

echo "effective_cpu_limits:"
docker inspect -f 'cpuset={{.HostConfig.CpusetCpus}} nanocpus={{.HostConfig.NanoCpus}}' "${CONTAINER}"

CONTAINERS="${CONTAINER}" ./scripts/bench-lighton-ocr-local.sh "${INPUT_PATH}" "${PAGE_INDEX}"
