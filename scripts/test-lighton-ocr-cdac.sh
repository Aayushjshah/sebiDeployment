#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
PAGE_INDEX="${2:-0}"
ENDPOINT="${ENDPOINT:-https://apis.airawat.cdac.in/msebisec-lightonocr/v1/chat/completions}"
MODEL="${MODEL:-lightonai/LightOnOCR-2-1B}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
TMP_DIR="${TMP_DIR:-/tmp/lighton-ocr-cdac-test}"
CDAC_CA_CERT="${CDAC_CA_CERT:-/root/Documents/sebiDeployment/pem/cdac-ca.pem}"
CDAC_PROXY="${CDAC_PROXY:-10.201.6.100:1080}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-180}"

if [ -z "${INPUT_PATH}" ] || [ ! -f "${INPUT_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf-or-image [zero_based_page_index]" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
[ -f "${CDAC_CA_CERT}" ] || { echo "missing CA certificate: ${CDAC_CA_CERT}" >&2; exit 1; }

TOKEN="${LIGHTON_ACCESS_TOKEN:-${CDAC_API_KEY:-}}"
if [ -z "${TOKEN}" ] && command -v docker >/dev/null 2>&1; then
  for container in lighton-ocr-wrapper xyne-lighton-ocr; do
    if docker inspect "${container}" >/dev/null 2>&1; then
      TOKEN="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${container}" | sed -n 's/^LIGHTON_ACCESS_TOKEN=//p' | tail -n 1)"
      [ -n "${TOKEN}" ] && break
    fi
  done
fi
[ -n "${TOKEN}" ] || { echo "LIGHTON_ACCESS_TOKEN or CDAC_API_KEY is required" >&2; exit 1; }

mkdir -p "${TMP_DIR}"
IMAGE_PATH="${TMP_DIR}/page.png"
PAYLOAD="${TMP_DIR}/request.json"
RESPONSE="${TMP_DIR}/response.json"

case "${INPUT_PATH,,}" in
  *.pdf)
    python3 - "${INPUT_PATH}" "${PAGE_INDEX}" "${IMAGE_PATH}" <<'PY'
import sys
from pathlib import Path

try:
    import pypdfium2 as pdfium
except ImportError:
    raise SystemExit("pypdfium2 is required for PDF input: python3 -m pip install pypdfium2")

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
    ;;
  *.png|*.jpg|*.jpeg|*.webp)
    cp "${INPUT_PATH}" "${IMAGE_PATH}"
    ;;
  *)
    echo "unsupported input type; use PDF, PNG, JPG, JPEG, or WEBP" >&2
    exit 1
    ;;
esac

python3 - "${PAYLOAD}" "${MODEL}" "${IMAGE_PATH}" "${MAX_TOKENS}" <<'PY'
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

proxy_args=()
if [ -n "${CDAC_PROXY}" ]; then
  proxy_url="${CDAC_PROXY}"
  case "${proxy_url}" in
    http://*|https://*) ;;
    *) proxy_url="http://${proxy_url}" ;;
  esac
  proxy_args=(--proxy "${proxy_url}")
fi

http_code="$(
  /usr/bin/time -f "latency_sec=%e" \
    curl --noproxy 'localhost,127.0.0.1' -sS \
      --connect-timeout 20 \
      --max-time "${REQUEST_TIMEOUT_SECONDS}" \
      "${proxy_args[@]}" \
      --cacert "${CDAC_CA_CERT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${TOKEN}" \
      -d "@${PAYLOAD}" \
      -o "${RESPONSE}" \
      -w "%{http_code}" \
      "${ENDPOINT}"
)"

echo "http_status=${http_code}"
if [ "${http_code}" != "200" ]; then
  echo "response_file=${RESPONSE}" >&2
  head -c 2000 "${RESPONSE}" >&2 || true
  echo >&2
  exit 1
fi

python3 - "${RESPONSE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
text = data["choices"][0]["message"]["content"]
if isinstance(text, list):
    print(json.dumps(text, ensure_ascii=False, indent=2))
else:
    print(text)
PY
