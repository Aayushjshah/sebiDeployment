#!/usr/bin/env bash
set -euo pipefail

CPUS="${CPUS:-32}"
CPUSET="${CPUSET:-0-31}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8003/health}"

if ! [[ "${CPUS}" =~ ^[0-9]+$ ]] || [ "${CPUS}" -lt 1 ]; then
  echo "CPUS must be a positive integer" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Recreating lighton-ocr-vllm-cpu with cpus=${CPUS} cpuset=${CPUSET}"

LIGHTON_OCR_VLLM_CPUS="${CPUS}" \
LIGHTON_OCR_VLLM_CPUSET="${CPUSET}" \
LIGHTON_OCR_VLLM_CPU_THREADS_BIND="${CPUSET}" \
docker compose \
  -f docker-compose.yml \
  -f docker-compose.lighton-ocr-vllm-cpu.yml \
  -f docker-compose.lighton-ocr-vllm-cpu-limit.yml \
  up -d --force-recreate lighton-ocr-vllm-cpu

docker inspect -f 'cpuset={{.HostConfig.CpusetCpus}} nanocpus={{.HostConfig.NanoCpus}} env_threads={{range .Config.Env}}{{println .}}{{end}}' lighton-ocr-vllm-cpu \
  | sed -n '1p;/^VLLM_CPU_OMP_THREADS_BIND=/p'

echo "Waiting for ${HEALTH_URL} ..."
deadline=$((SECONDS + WAIT_SECONDS))
until curl --noproxy '*' -fsS "${HEALTH_URL}" >/dev/null 2>&1; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "Timed out waiting for LightOnOCR health" >&2
    docker logs --tail 200 lighton-ocr-vllm-cpu >&2 || true
    exit 1
  fi
  sleep 5
done

echo "LightOnOCR vLLM is healthy with cpus=${CPUS} cpuset=${CPUSET}"
