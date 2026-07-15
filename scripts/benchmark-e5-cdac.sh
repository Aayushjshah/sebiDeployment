#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/benchmark-e5-cdac.sh [output_dir]

Benchmarks the CDAC/GPU hosted E5 /v1/embeddings endpoint with the same
REQUESTS / CONCURRENCY / BATCH_SIZE / TOKENS_PER_CHUNK semantics as the local
CPU benchmark. This measures client-side latency and throughput only; it cannot
sample remote GPU docker stats.

Environment:
  CDAC_API_KEY              bearer token, unless CDAC_AUTHORIZATION is set
  CDAC_AUTHORIZATION        full Authorization header value
  CDAC_EMBEDDINGS_URL       default: https://apis.airawat.cdac.in/msebisec/v1/embeddings
  CDAC_PROXY                default: 10.201.6.100:1080; set to "none" to disable
  CDAC_CA_CERT              default: pem/cdac-ca.pem when present
  MODEL                     default: intfloat/multilingual-e5-large-instruct
  REQUESTS                  default: 100
  CONCURRENCY               default: 1
  BATCH_SIZE                default: 1
  TOKENS_PER_CHUNK          default: 460
  INPUT_FILE                optional: repeat this text as every chunk
  INPUT_DIR                 optional: use *.txt files from this directory
  REQUEST_TIMEOUT_SECONDS   default: 300
  PROGRESS_EVERY            default: 10

Examples:
  CDAC_API_KEY=... REQUESTS=20 CONCURRENCY=1 BATCH_SIZE=1 \
    scripts/benchmark-e5-cdac.sh /tmp/e5-cdac-c1

  CDAC_API_KEY=... REQUESTS=100 CONCURRENCY=4 BATCH_SIZE=1 \
    scripts/benchmark-e5-cdac.sh /tmp/e5-cdac-c4
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -f "${REPO_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_DIR}/.env"
  set +a
fi

CDAC_EMBEDDINGS_URL="${CDAC_EMBEDDINGS_URL:-https://apis.airawat.cdac.in/msebisec/v1/embeddings}"
CDAC_PROXY="${CDAC_PROXY:-10.201.6.100:1080}"
CDAC_CA_CERT="${CDAC_CA_CERT:-${REPO_DIR}/pem/cdac-ca.pem}"
MODEL="${MODEL:-intfloat/multilingual-e5-large-instruct}"
REQUESTS="${REQUESTS:-100}"
CONCURRENCY="${CONCURRENCY:-1}"
BATCH_SIZE="${BATCH_SIZE:-1}"
TOKENS_PER_CHUNK="${TOKENS_PER_CHUNK:-460}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-300}"
PROGRESS_EVERY="${PROGRESS_EVERY:-10}"
OUTPUT_DIR="${1:-/tmp/e5-cdac-bench-$(date +%Y%m%d-%H%M%S)}"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

auth_header="${CDAC_AUTHORIZATION:-}"
if [ -z "${auth_header}" ]; then
  token="${CDAC_API_KEY:-${UPSTREAM_API_KEY:-${VESPA_SECRET_CDAC_API_KEY:-}}}"
  [ -n "${token}" ] || { echo "Set CDAC_API_KEY or CDAC_AUTHORIZATION" >&2; exit 1; }
  auth_header="Bearer ${token}"
fi

mkdir -p "${OUTPUT_DIR}"
LATENCY_CSV="${OUTPUT_DIR}/latencies.csv"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_TXT="${OUTPUT_DIR}/summary.txt"

proxy_url=""
if [ -n "${CDAC_PROXY}" ] && [ "${CDAC_PROXY}" != "none" ]; then
  case "${CDAC_PROXY}" in
    http://*|https://*) proxy_url="${CDAC_PROXY}" ;;
    *) proxy_url="http://${CDAC_PROXY}" ;;
  esac
fi

ca_cert=""
if [ -f "${CDAC_CA_CERT}" ]; then
  ca_cert="${CDAC_CA_CERT}"
fi

echo "output_dir=${OUTPUT_DIR}"
echo "endpoint=${CDAC_EMBEDDINGS_URL}"
echo "proxy=${proxy_url:-none}"
echo "ca_cert=${ca_cert:-system}"
echo "requests=${REQUESTS} concurrency=${CONCURRENCY} batch_size=${BATCH_SIZE} tokens_per_chunk=${TOKENS_PER_CHUNK}"

CDAC_EMBEDDINGS_URL="${CDAC_EMBEDDINGS_URL}" \
CDAC_AUTHORIZATION_VALUE="${auth_header}" \
CDAC_PROXY_URL="${proxy_url}" \
CDAC_CA_CERT_FILE="${ca_cert}" \
MODEL="${MODEL}" \
REQUESTS="${REQUESTS}" \
CONCURRENCY="${CONCURRENCY}" \
BATCH_SIZE="${BATCH_SIZE}" \
TOKENS_PER_CHUNK="${TOKENS_PER_CHUNK}" \
INPUT_FILE="${INPUT_FILE:-}" \
INPUT_DIR="${INPUT_DIR:-}" \
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS}" \
PROGRESS_EVERY="${PROGRESS_EVERY}" \
LATENCY_CSV="${LATENCY_CSV}" \
SUMMARY_JSON="${SUMMARY_JSON}" \
SUMMARY_TXT="${SUMMARY_TXT}" \
python3 - <<'PY'
import concurrent.futures
import csv
import json
import os
import pathlib
import ssl
import statistics
import sys
import time
import urllib.error
import urllib.request

endpoint = os.environ["CDAC_EMBEDDINGS_URL"]
auth_header = os.environ["CDAC_AUTHORIZATION_VALUE"]
proxy_url = os.environ.get("CDAC_PROXY_URL") or ""
ca_cert = os.environ.get("CDAC_CA_CERT_FILE") or ""
model = os.environ["MODEL"]
requests_total = int(os.environ["REQUESTS"])
concurrency = int(os.environ["CONCURRENCY"])
batch_size = int(os.environ["BATCH_SIZE"])
tokens_per_chunk = int(os.environ["TOKENS_PER_CHUNK"])
timeout = float(os.environ["REQUEST_TIMEOUT_SECONDS"])
progress_every = int(os.environ["PROGRESS_EVERY"])
latency_csv = pathlib.Path(os.environ["LATENCY_CSV"])
summary_json = pathlib.Path(os.environ["SUMMARY_JSON"])
summary_txt = pathlib.Path(os.environ["SUMMARY_TXT"])
input_file = os.environ.get("INPUT_FILE") or ""
input_dir = os.environ.get("INPUT_DIR") or ""

handlers = []
if proxy_url:
    handlers.append(urllib.request.ProxyHandler({"http": proxy_url, "https": proxy_url}))
else:
    handlers.append(urllib.request.ProxyHandler({}))
if ca_cert:
    handlers.append(urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=ca_cert)))
opener = urllib.request.build_opener(*handlers)


def generated_chunk(i: int) -> str:
    seed = [
        "query:",
        "SEBI",
        "disclosure",
        "requirements",
        "listed",
        "entity",
        "regulation",
        "securities",
        "market",
        "compliance",
        "annual",
        "report",
        "board",
        "meeting",
        "investor",
        "protection",
        "penalty",
        "appeal",
        "order",
        str(i),
    ]
    words = []
    while len(words) < tokens_per_chunk:
        words.extend(seed)
    return " ".join(words[:tokens_per_chunk])


def load_texts() -> list[str]:
    if input_file:
        return [pathlib.Path(input_file).read_text(encoding="utf-8")]
    if input_dir:
        files = sorted(pathlib.Path(input_dir).glob("*.txt"))
        if not files:
            raise SystemExit(f"no .txt files found in INPUT_DIR={input_dir}")
        return [p.read_text(encoding="utf-8") for p in files]
    return [generated_chunk(i) for i in range(max(requests_total * batch_size, 1))]


texts = load_texts()


def request_body(request_id: int) -> bytes:
    start = request_id * batch_size
    batch = [texts[(start + i) % len(texts)] for i in range(batch_size)]
    return json.dumps(
        {
            "input": batch,
            "model": model,
            "encoding_format": "float",
        },
        ensure_ascii=False,
    ).encode("utf-8")


def run_one(request_id: int) -> dict:
    body = request_body(request_id)
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": auth_header,
        },
        method="POST",
    )
    started = time.perf_counter()
    status = 0
    items = 0
    dim = 0
    error = ""
    try:
        with opener.open(req, timeout=timeout) as resp:
            status = resp.status
            payload = json.loads(resp.read().decode("utf-8"))
        data = payload.get("data") or []
        items = len(data)
        dim = len(data[0].get("embedding") or []) if data else 0
        if status != 200 or items != batch_size or dim != 1024:
            error = f"unexpected response status={status} items={items} dim={dim}"
    except urllib.error.HTTPError as exc:
        status = exc.code
        error = exc.read().decode("utf-8", errors="replace")[:500]
    except Exception as exc:
        error = repr(exc)
    latency = time.perf_counter() - started
    return {
        "request_id": request_id,
        "latency_sec": latency,
        "status": status,
        "items": items,
        "dim": dim,
        "error": error,
    }


started = time.perf_counter()
results = []
completed = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
    future_to_id = {pool.submit(run_one, i): i for i in range(requests_total)}
    for future in concurrent.futures.as_completed(future_to_id):
        result = future.result()
        results.append(result)
        completed += 1
        if progress_every > 0 and (completed % progress_every == 0 or completed == requests_total):
            ok = sum(1 for r in results if not r["error"])
            print(f"completed={completed}/{requests_total} ok={ok}", file=sys.stderr)

wall = time.perf_counter() - started
results.sort(key=lambda r: r["request_id"])
with latency_csv.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=["request_id", "latency_sec", "status", "items", "dim", "error"],
    )
    writer.writeheader()
    writer.writerows(results)

errors = [r for r in results if r["error"]]
if errors:
    print(f"errors={len(errors)}; first_error={errors[0]['error']}", file=sys.stderr)
    raise SystemExit(2)

latencies = [r["latency_sec"] for r in results]
latencies_sorted = sorted(latencies)


def percentile(p: float) -> float:
    if not latencies_sorted:
        return 0.0
    idx = min(len(latencies_sorted) - 1, max(0, int(round((p / 100) * (len(latencies_sorted) - 1)))))
    return latencies_sorted[idx]


summary = {
    "requests": requests_total,
    "batch_size": batch_size,
    "chunks": requests_total * batch_size,
    "concurrency": concurrency,
    "wall_sec": wall,
    "requests_per_sec": requests_total / wall if wall else 0.0,
    "chunks_per_sec": (requests_total * batch_size) / wall if wall else 0.0,
    "latency_avg_sec": statistics.mean(latencies) if latencies else 0.0,
    "latency_p50_sec": percentile(50),
    "latency_p95_sec": percentile(95),
    "latency_p99_sec": percentile(99),
    "latency_max_sec": max(latencies) if latencies else 0.0,
    "endpoint": endpoint,
    "proxy": proxy_url or "none",
}
summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
lines = [
    f"requests={summary['requests']} batch_size={summary['batch_size']} chunks={summary['chunks']} concurrency={summary['concurrency']}",
    f"wall_sec={summary['wall_sec']:.3f} requests_per_sec={summary['requests_per_sec']:.3f} chunks_per_sec={summary['chunks_per_sec']:.3f}",
    f"latency_sec avg={summary['latency_avg_sec']:.3f} p50={summary['latency_p50_sec']:.3f} p95={summary['latency_p95_sec']:.3f} p99={summary['latency_p99_sec']:.3f} max={summary['latency_max_sec']:.3f}",
    f"latencies_csv={latency_csv}",
    f"summary_json={summary_json}",
]
summary_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2))
print("\n".join(lines))
PY

echo "summary=${SUMMARY_TXT}"
