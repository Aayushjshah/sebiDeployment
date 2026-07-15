#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/benchmark-e5-cpu-stats.sh [output_dir]

Benchmarks the locally hosted CPU E5 /v1/embeddings endpoint while sampling
docker stats for the E5 container. It can generate synthetic ~460-token chunks
or reuse text from a file/directory.

Environment:
  CONTAINER                 default: e5-tei-cpu
  ENDPOINT                  default: http://localhost:8093/v1/embeddings
  MODEL                     default: intfloat/multilingual-e5-large-instruct
  REQUESTS                  default: 100
  CONCURRENCY               default: 4
  BATCH_SIZE                default: 1
  TOKENS_PER_CHUNK          default: 460
  INPUT_FILE                optional: repeat this text as every chunk
  INPUT_DIR                 optional: use *.txt files from this directory
  REQUEST_TIMEOUT_SECONDS   default: 120
  STATS_INTERVAL_SECONDS    default: 1
  PROGRESS_EVERY            default: 10
  USE_PROXY                 default: false; set true only for remote endpoints

Examples:
  REQUESTS=100 CONCURRENCY=4 BATCH_SIZE=1 scripts/benchmark-e5-cpu-stats.sh

  INPUT_DIR=/tmp/chunks REQUESTS=500 CONCURRENCY=8 \\
    scripts/benchmark-e5-cpu-stats.sh /tmp/e5-bench-500x8
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

CONTAINER="${CONTAINER:-e5-tei-cpu}"
ENDPOINT="${ENDPOINT:-http://localhost:8093/v1/embeddings}"
MODEL="${MODEL:-intfloat/multilingual-e5-large-instruct}"
REQUESTS="${REQUESTS:-100}"
CONCURRENCY="${CONCURRENCY:-4}"
BATCH_SIZE="${BATCH_SIZE:-1}"
TOKENS_PER_CHUNK="${TOKENS_PER_CHUNK:-460}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-120}"
STATS_INTERVAL_SECONDS="${STATS_INTERVAL_SECONDS:-1}"
PROGRESS_EVERY="${PROGRESS_EVERY:-10}"
USE_PROXY="${USE_PROXY:-false}"
OUTPUT_DIR="${1:-/tmp/e5-bench-$(date +%Y%m%d-%H%M%S)}"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

mkdir -p "${OUTPUT_DIR}"

LATENCY_CSV="${OUTPUT_DIR}/latencies.csv"
STATS_TSV="${OUTPUT_DIR}/docker-stats.tsv"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_TXT="${OUTPUT_DIR}/summary.txt"

if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "Container not found: ${CONTAINER}" >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}")" != "true" ]; then
  echo "Container is not running: ${CONTAINER}" >&2
  exit 1
fi

HOST_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"

echo "output_dir=${OUTPUT_DIR}"
echo "container=${CONTAINER}"
echo "endpoint=${ENDPOINT}"
echo "requests=${REQUESTS} concurrency=${CONCURRENCY} batch_size=${BATCH_SIZE} tokens_per_chunk=${TOKENS_PER_CHUNK}"

echo -e "timestamp\tcpu_perc\tmem_usage\tmem_perc\tpids" > "${STATS_TSV}"
(
  while true; do
    sample="$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' "${CONTAINER}" 2>/dev/null || true)"
    if [ -n "${sample}" ]; then
      printf "%s\t%s\n" "$(date +%s.%N)" "${sample}" >> "${STATS_TSV}"
    fi
    sleep "${STATS_INTERVAL_SECONDS}"
  done
) &
STATS_PID="$!"

cleanup() {
  kill "${STATS_PID}" >/dev/null 2>&1 || true
  wait "${STATS_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

set +e
ENDPOINT="${ENDPOINT}" \
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
USE_PROXY="${USE_PROXY}" \
python3 - <<'PY'
import concurrent.futures
import csv
import json
import os
import pathlib
import statistics
import sys
import time
import urllib.error
import urllib.request

endpoint = os.environ["ENDPOINT"]
model = os.environ["MODEL"]
requests_total = int(os.environ["REQUESTS"])
concurrency = int(os.environ["CONCURRENCY"])
batch_size = int(os.environ["BATCH_SIZE"])
tokens_per_chunk = int(os.environ["TOKENS_PER_CHUNK"])
timeout = float(os.environ["REQUEST_TIMEOUT_SECONDS"])
progress_every = int(os.environ["PROGRESS_EVERY"])
latency_csv = pathlib.Path(os.environ["LATENCY_CSV"])
input_file = os.environ.get("INPUT_FILE") or ""
input_dir = os.environ.get("INPUT_DIR") or ""
use_proxy = os.environ.get("USE_PROXY", "false").lower() in {"1", "true", "yes"}
opener = urllib.request.build_opener() if use_proxy else urllib.request.build_opener(urllib.request.ProxyHandler({}))


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
        headers={"Content-Type": "application/json"},
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
}
pathlib.Path(os.environ["LATENCY_CSV"] + ".summary.json").write_text(
    json.dumps(summary, indent=2), encoding="utf-8"
)
print(json.dumps(summary, indent=2))
PY
BENCH_RC="$?"
set -e

cleanup
trap - EXIT

python3 - "${LATENCY_CSV}.summary.json" "${STATS_TSV}" "${SUMMARY_JSON}" "${SUMMARY_TXT}" "${HOST_CPUS}" <<'PY'
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

bench_summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")) if Path(sys.argv[1]).exists() else {}
stats_path = Path(sys.argv[2])
summary_json = Path(sys.argv[3])
summary_txt = Path(sys.argv[4])
host_cpus = float(sys.argv[5])


def parse_percent(value: str) -> float:
    return float(value.strip().rstrip("%") or 0)


def parse_bytes(value: str) -> float:
    value = value.strip()
    match = re.match(r"([0-9.]+)\s*([A-Za-z]+)", value)
    if not match:
        return 0.0
    number = float(match.group(1))
    unit = match.group(2).lower()
    factors = {
        "b": 1,
        "kb": 1000,
        "mb": 1000**2,
        "gb": 1000**3,
        "tb": 1000**4,
        "kib": 1024,
        "mib": 1024**2,
        "gib": 1024**3,
        "tib": 1024**4,
    }
    return number * factors.get(unit, 1)


rows = []
with stats_path.open(encoding="utf-8") as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        if not row.get("cpu_perc"):
            continue
        mem_usage = (row.get("mem_usage") or "").split("/", 1)[0].strip()
        mem_limit = (row.get("mem_usage") or "").split("/", 1)[1].strip() if "/" in (row.get("mem_usage") or "") else ""
        rows.append(
            {
                "cpu_perc": parse_percent(row["cpu_perc"]),
                "mem_used_bytes": parse_bytes(mem_usage),
                "mem_limit_bytes": parse_bytes(mem_limit),
                "mem_perc": parse_percent(row.get("mem_perc") or "0%"),
                "pids": int((row.get("pids") or "0").strip() or 0),
            }
        )


def avg(values):
    return statistics.mean(values) if values else 0.0


cpu_values = [r["cpu_perc"] for r in rows]
mem_values = [r["mem_used_bytes"] for r in rows]
mem_limit_values = [r["mem_limit_bytes"] for r in rows if r["mem_limit_bytes"] > 0]
mem_limit = max(mem_limit_values) if mem_limit_values else 0.0
avg_cpu = avg(cpu_values)
max_cpu = max(cpu_values) if cpu_values else 0.0
avg_mem = avg(mem_values)
max_mem = max(mem_values) if mem_values else 0.0

target_cpu_util = 0.80
target_mem_util = 0.80
cpu_capacity = math.floor((host_cpus * 100.0 * target_cpu_util) / avg_cpu) if avg_cpu > 0 else 0
mem_capacity = math.floor((mem_limit * target_mem_util) / max_mem) if mem_limit > 0 and max_mem > 0 else 0

summary = {
    **bench_summary,
    "docker_stats_samples": len(rows),
    "host_cpus": host_cpus,
    "cpu_avg_perc": avg_cpu,
    "cpu_max_perc": max_cpu,
    "mem_avg_bytes": avg_mem,
    "mem_max_bytes": max_mem,
    "mem_limit_bytes": mem_limit,
    "mem_avg_gib": avg_mem / (1024**3),
    "mem_max_gib": max_mem / (1024**3),
    "mem_limit_gib": mem_limit / (1024**3) if mem_limit else 0.0,
    "capacity_hint_by_avg_cpu_at_80pct": cpu_capacity,
    "capacity_hint_by_max_mem_at_80pct": mem_capacity,
}
summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

lines = [
    f"requests={summary.get('requests', 0)} batch_size={summary.get('batch_size', 0)} chunks={summary.get('chunks', 0)} concurrency={summary.get('concurrency', 0)}",
    f"wall_sec={summary.get('wall_sec', 0):.3f} requests_per_sec={summary.get('requests_per_sec', 0):.3f} chunks_per_sec={summary.get('chunks_per_sec', 0):.3f}",
    f"latency_sec avg={summary.get('latency_avg_sec', 0):.3f} p50={summary.get('latency_p50_sec', 0):.3f} p95={summary.get('latency_p95_sec', 0):.3f} p99={summary.get('latency_p99_sec', 0):.3f} max={summary.get('latency_max_sec', 0):.3f}",
    f"docker_stats_samples={len(rows)} host_cpus={host_cpus:.0f}",
    f"cpu_perc avg={avg_cpu:.2f} max={max_cpu:.2f}  # 100% ~= one full CPU core",
    f"memory_gib avg={summary['mem_avg_gib']:.3f} max={summary['mem_max_gib']:.3f} limit={summary['mem_limit_gib']:.3f}",
    f"capacity_hint_by_avg_cpu_at_80pct={cpu_capacity}",
    f"capacity_hint_by_max_mem_at_80pct={mem_capacity}",
    f"latencies_csv={Path(sys.argv[1]).with_suffix('').as_posix()}",
    f"docker_stats_tsv={stats_path}",
    f"summary_json={summary_json}",
]
summary_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines))
PY

echo "summary=${SUMMARY_TXT}"
exit "${BENCH_RC}"
