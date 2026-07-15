#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/embed-e5-cdac-file.sh <input.txt> [output.json]

Reads the exact text from input.txt and sends it to the CDAC/GPU hosted E5
OpenAI-compatible /v1/embeddings endpoint. If output.json is omitted, the raw
JSON response is printed to stdout.

Environment:
  CDAC_API_KEY       bearer token, unless CDAC_AUTHORIZATION is set
  CDAC_AUTHORIZATION full Authorization header value
  CDAC_EMBEDDINGS_URL default: https://apis.airawat.cdac.in/msebisec/v1/embeddings
  CDAC_PROXY         default: 10.201.6.100:1080; set to "none" to disable
  CDAC_CA_CERT       default: pem/cdac-ca.pem when present
  MODEL              default: intfloat/multilingual-e5-large-instruct
  E5_INPUT_PREFIX    optional text prepended to file content
EOF
}

if [ -f "${REPO_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

INPUT_FILE="${1:-}"
OUTPUT_FILE="${2:-}"
CDAC_EMBEDDINGS_URL="${CDAC_EMBEDDINGS_URL:-https://apis.airawat.cdac.in/msebisec/v1/embeddings}"
CDAC_PROXY="${CDAC_PROXY:-10.201.6.100:1080}"
CDAC_CA_CERT="${CDAC_CA_CERT:-${REPO_DIR}/pem/cdac-ca.pem}"
MODEL="${MODEL:-intfloat/multilingual-e5-large-instruct}"

if [ -z "${INPUT_FILE}" ] || [ "${INPUT_FILE}" = "-h" ] || [ "${INPUT_FILE}" = "--help" ]; then
  usage
  exit 1
fi

[ -f "${INPUT_FILE}" ] || { echo "Input file not found: ${INPUT_FILE}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

auth_header="${CDAC_AUTHORIZATION:-}"
if [ -z "${auth_header}" ]; then
  token="${CDAC_API_KEY:-${UPSTREAM_API_KEY:-${VESPA_SECRET_CDAC_API_KEY:-}}}"
  [ -n "${token}" ] || { echo "Set CDAC_API_KEY or CDAC_AUTHORIZATION" >&2; exit 1; }
  auth_header="Bearer ${token}"
fi

payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "${payload_file}" "${response_file}"' EXIT

python3 - "${INPUT_FILE}" "${MODEL}" > "${payload_file}" <<'PY'
import json
import os
import pathlib
import sys

input_file, model = sys.argv[1], sys.argv[2]
text = pathlib.Path(input_file).read_text(encoding=os.environ.get("INPUT_ENCODING", "utf-8"))
text = os.environ.get("E5_INPUT_PREFIX", "") + text
payload = {
    "input": [text],
    "model": model,
    "encoding_format": os.environ.get("ENCODING_FORMAT", "float"),
}
if os.environ.get("DIMENSIONS"):
    payload["dimensions"] = int(os.environ["DIMENSIONS"])
print(json.dumps(payload, ensure_ascii=False))
PY

curl_args=(
  -fsS
  "${CDAC_EMBEDDINGS_URL}"
  -H "Content-Type: application/json"
  -H "Authorization: ${auth_header}"
  -d @"${payload_file}"
  -o "${response_file}"
)

if [ -n "${CDAC_PROXY}" ] && [ "${CDAC_PROXY}" != "none" ]; then
  case "${CDAC_PROXY}" in
    http://*|https://*) proxy_url="${CDAC_PROXY}" ;;
    *) proxy_url="http://${CDAC_PROXY}" ;;
  esac
  curl_args=(--proxy "${proxy_url}" "${curl_args[@]}")
fi

if [ -f "${CDAC_CA_CERT}" ]; then
  curl_args=(--cacert "${CDAC_CA_CERT}" "${curl_args[@]}")
fi

curl "${curl_args[@]}"

python3 - "${response_file}" "${OUTPUT_FILE:-}" >&2 <<'PY'
import json
import sys

response_file, output_file = sys.argv[1], sys.argv[2]
payload = json.load(open(response_file, encoding="utf-8"))
items = payload.get("data") or []
dim = len(items[0].get("embedding") or []) if items else 0
suffix = f" output={output_file}" if output_file else ""
print(f"items={len(items)} dim={dim} model={payload.get('model', '')}{suffix}")
if len(items) != 1 or dim != 1024:
    raise SystemExit("expected one 1024-dimensional embedding")
PY

if [ -n "${OUTPUT_FILE}" ]; then
  cp "${response_file}" "${OUTPUT_FILE}"
else
  cat "${response_file}"
fi
