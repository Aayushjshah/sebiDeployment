#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="$(cd "${REPO_DIR}/.." && pwd)"

cd "${REPO_DIR}"

IMAGE_TAG="${IMAGE_TAG:-e5-tei-cpu:sebi-20260714}"
MODEL_ID="${MODEL_ID:-intfloat/multilingual-e5-large-instruct}"
BASE_IMAGE="${TEI_CPU_BASE_IMAGE:-ghcr.io/huggingface/text-embeddings-inference:cpu-1.9}"
PLATFORM="${PLATFORM:-linux/amd64}"
OUT_DIR="${OUT_DIR:-${BUNDLE_DIR}/images}"
TAR_NAME="${TAR_NAME:-e5-tei-cpu-sebi-20260714.tar}"

mkdir -p "${OUT_DIR}"

build_args=(
  --platform "${PLATFORM}"
  --build-arg "TEI_CPU_BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "MODEL_ID=${MODEL_ID}"
)

if [ -n "${HF_TOKEN:-}" ]; then
  build_args+=(--build-arg "HF_TOKEN=${HF_TOKEN}")
fi

docker build \
  "${build_args[@]}" \
  -f Dockerfile.e5-tei-cpu \
  -t "${IMAGE_TAG}" \
  .

docker save "${IMAGE_TAG}" -o "${OUT_DIR}/${TAR_NAME}"

cat <<EOF
Built image: ${IMAGE_TAG}
Saved tar:   ${OUT_DIR}/${TAR_NAME}

Load on the air-gapped VM with:

  docker load -i ${TAR_NAME}

Then run it with docker-compose.e5-tei-cpu.yml and hit:

  http://localhost:8093/v1/embeddings
EOF
