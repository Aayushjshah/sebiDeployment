#!/usr/bin/env bash
set -euo pipefail

PDF_PATH="${1:-}"
PAGE_INDEX="${2:-0}"
ENDPOINT="${ENDPOINT:-http://localhost:8003/v1/chat/completions}"
MODEL="${MODEL:-lightonai/LightOnOCR-2-1B-bbox}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
TMP_DIR="${TMP_DIR:-/tmp/lighton-ocr-vllm-cpu-test}"

if [ -z "${PDF_PATH}" ] || [ ! -f "${PDF_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf [zero_based_page_index]" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

mkdir -p "${TMP_DIR}"

python3 - "${PDF_PATH}" "${PAGE_INDEX}" "${TMP_DIR}/page.png" <<'PY'
import sys
from pathlib import Path

try:
    import pypdfium2 as pdfium
except ImportError:
    raise SystemExit("pypdfium2 is required on the host for this test: pip install pypdfium2")

pdf_path = sys.argv[1]
page_index = int(sys.argv[2])
out = Path(sys.argv[3])
pdf = pdfium.PdfDocument(pdf_path)
page = pdf[page_index]
w, h = page.get_size()
scale = 1540 / max(w, h)
image = page.render(scale=scale).to_pil().convert("RGB")
image.save(out)
print(out)
PY

PAYLOAD="${TMP_DIR}/request.json"
RESPONSE="${TMP_DIR}/response.json"

python3 - "${PAYLOAD}" "${MODEL}" "${TMP_DIR}/page.png" "${MAX_TOKENS}" <<'PY'
import base64
import json
import sys

out, model, image_path, max_tokens = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(image_path, "rb") as f:
    image_b64 = base64.b64encode(f.read()).decode("ascii")

payload = {
    "model": model,
    "messages": [{
        "role": "user",
        "content": [{
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{image_b64}"}
        }]
    }],
    "max_tokens": max_tokens,
    "temperature": 0.0,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY

/usr/bin/time -f "latency_sec=%e" \
  curl --noproxy '*' -fsS \
    -H "Content-Type: application/json" \
    -d "@${PAYLOAD}" \
    "${ENDPOINT}" \
    -o "${RESPONSE}"

python3 - "${RESPONSE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
text = data["choices"][0]["message"]["content"]
print(text)
PY
