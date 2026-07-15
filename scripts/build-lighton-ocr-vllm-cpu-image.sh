#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="$(cd "${REPO_DIR}/.." && pwd)"

cd "${REPO_DIR}"

IMAGE_TAG="${IMAGE_TAG:-lighton-ocr-vllm-cpu:sebi-20260714}"
MODEL_ID="${MODEL_ID:-lightonai/LightOnOCR-2-1B-bbox}"
BASE_IMAGE="${VLLM_CPU_BASE_IMAGE:-vllm/vllm-openai-cpu:latest-x86_64}"
PLATFORM="${PLATFORM:-linux/amd64}"
OUT_DIR="${OUT_DIR:-${BUNDLE_DIR}/images}"
TAR_NAME="${TAR_NAME:-lighton-ocr-vllm-cpu-sebi-20260714.tar}"

mkdir -p "${OUT_DIR}"

docker build \
  --platform "${PLATFORM}" \
  --build-arg "VLLM_CPU_BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "MODEL_ID=${MODEL_ID}" \
  -f Dockerfile.lighton-ocr-vllm-cpu \
  -t "${IMAGE_TAG}" \
  .

docker save "${IMAGE_TAG}" -o "${OUT_DIR}/${TAR_NAME}"

cat <<EOF
Built image: ${IMAGE_TAG}
Saved tar:   ${OUT_DIR}/${TAR_NAME}

Move this tar into the air-gapped bundle's images/ directory before running start.sh,
or load it manually on the VM with:

  docker load -i ${TAR_NAME}
EOF
