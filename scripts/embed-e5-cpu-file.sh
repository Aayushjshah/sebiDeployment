#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/embed-e5-cpu-file.sh <input.txt> [output.json]

Reads the exact text from input.txt and sends it to the locally hosted CPU E5
OpenAI-compatible /v1/embeddings endpoint. If output.json is omitted, the raw
JSON response is printed to stdout.

Environment:
  ENDPOINT          default: http://localhost:8093/v1/embeddings
  MODEL             default: intfloat/multilingual-e5-large-instruct
  E5_INPUT_PREFIX   optional text prepended to file content
EOF
}

INPUT_FILE="${1:-}"
OUTPUT_FILE="${2:-}"
ENDPOINT="${ENDPOINT:-http://localhost:8093/v1/embeddings}"
MODEL="${MODEL:-intfloat/multilingual-e5-large-instruct}"

if [ -z "${INPUT_FILE}" ] || [ "${INPUT_FILE}" = "-h" ] || [ "${INPUT_FILE}" = "--help" ]; then
  usage
  exit 1
fi

[ -f "${INPUT_FILE}" ] || { echo "Input file not found: ${INPUT_FILE}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

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

curl --noproxy '*' -fsS "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d @"${payload_file}" \
  -o "${response_file}"

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
