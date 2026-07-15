#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://localhost:8093/v1/embeddings}"
MODEL="${MODEL:-intfloat/multilingual-e5-large-instruct}"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

curl -fsS "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d "{\"input\":[\"query: hello world\"],\"model\":\"${MODEL}\",\"encoding_format\":\"float\"}" \
  > "${tmp}"

python3 - "${tmp}" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1]))
items = payload.get("data") or []
dim = len(items[0].get("embedding") or []) if items else 0
print(f"items={len(items)} dim={dim} model={payload.get('model', '')}")
if len(items) != 1 or dim != 1024:
    raise SystemExit("expected one 1024-dimensional embedding")
PY
