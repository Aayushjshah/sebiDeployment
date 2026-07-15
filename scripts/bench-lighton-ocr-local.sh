#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
PAGE_INDEX="${2:-0}"

ENDPOINT="${ENDPOINT:-http://localhost:8003/v1/chat/completions}"
MODEL="${MODEL:-lightonai/LightOnOCR-2-1B-bbox}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
REQUESTS="${REQUESTS:-5}"
CONCURRENCY="${CONCURRENCY:-1}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-1}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-900}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
CONTAINERS="${CONTAINERS:-lighton-ocr-vllm-cpu}"
TMP_DIR="${TMP_DIR:-/tmp/lighton-ocr-bench-$(date +%Y%m%d-%H%M%S)}"

if [ -z "${INPUT_PATH}" ] || [ ! -f "${INPUT_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf-or-image [zero_based_page_index]" >&2
  echo "env: REQUESTS=5 CONCURRENCY=1 WARMUP_REQUESTS=1 CONTAINERS=lighton-ocr-vllm-cpu" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

mkdir -p "${TMP_DIR}/responses" "${TMP_DIR}/errors"

IMAGE_PATH="${TMP_DIR}/page.png"
PAYLOAD="${TMP_DIR}/request.json"
REQUESTS_CSV="${TMP_DIR}/requests.csv"
HOST_METRICS_CSV="${TMP_DIR}/host_metrics.csv"
DOCKER_STATS_JSONL="${TMP_DIR}/docker_stats.jsonl"
DMESG_BEFORE="${TMP_DIR}/dmesg_oom_before.txt"
DMESG_AFTER="${TMP_DIR}/dmesg_oom_after.txt"
SUMMARY="${TMP_DIR}/summary.txt"

render_input() {
  case "${INPUT_PATH,,}" in
    *.pdf)
      if python3 -c 'import pypdfium2' >/dev/null 2>&1; then
        python3 - "${INPUT_PATH}" "${PAGE_INDEX}" "${IMAGE_PATH}" <<'PY'
import sys
from pathlib import Path
import pypdfium2 as pdfium

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
      elif command -v pdftoppm >/dev/null 2>&1; then
        local page_one_based=$((PAGE_INDEX + 1))
        pdftoppm -png -f "${page_one_based}" -l "${page_one_based}" -singlefile -r 180 "${INPUT_PATH}" "${TMP_DIR}/page"
        mv "${TMP_DIR}/page.png" "${IMAGE_PATH}"
        echo "${IMAGE_PATH}"
      else
        echo "PDF input requires either pypdfium2 or pdftoppm" >&2
        exit 1
      fi
      ;;
    *.png|*.jpg|*.jpeg|*.webp)
      cp "${INPUT_PATH}" "${IMAGE_PATH}"
      echo "${IMAGE_PATH}"
      ;;
    *)
      echo "unsupported input type; use PDF, PNG, JPG, JPEG, or WEBP" >&2
      exit 1
      ;;
  esac
}

build_payload() {
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
}

disk_avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

sample_metrics() {
  echo "ts_epoch,ts_iso,mem_total_kb,mem_available_kb,mem_free_kb,swap_total_kb,swap_free_kb,load1,load5,load15,root_avail_kb,data_avail_kb,docker_avail_kb" > "${HOST_METRICS_CSV}"
  while true; do
    local ts iso mem_total mem_available mem_free swap_total swap_free load1 load5 load15 root_avail data_avail docker_avail
    ts="$(date +%s)"
    iso="$(date -Is)"
    mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    mem_available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    mem_free="$(awk '/^MemFree:/ {print $2}' /proc/meminfo)"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
    read -r load1 load5 load15 _ < /proc/loadavg
    root_avail="$(disk_avail_kb / || true)"
    data_avail="$(disk_avail_kb /data || true)"
    docker_avail="$(disk_avail_kb /var/lib/docker || true)"
    echo "${ts},${iso},${mem_total},${mem_available},${mem_free},${swap_total},${swap_free},${load1},${load5},${load15},${root_avail:-},${data_avail:-},${docker_avail:-}" >> "${HOST_METRICS_CSV}"

    local stats
    stats="$(docker stats --no-stream --format '{{json .}}' ${CONTAINERS} 2>/dev/null || true)"
    if [ -n "${stats}" ]; then
      while IFS= read -r line; do
        [ -n "${line}" ] && printf '{"ts_epoch":%s,"ts_iso":"%s","docker":%s}\n' "${ts}" "${iso}" "${line}" >> "${DOCKER_STATS_JSONL}"
      done <<< "${stats}"
    fi
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

run_request() {
  local phase="$1"
  local idx="$2"
  local response="${TMP_DIR}/responses/${phase}_${idx}.json"
  local error_log="${TMP_DIR}/errors/${phase}_${idx}.err"
  local meta="${TMP_DIR}/${phase}_${idx}.meta"
  local started ended curl_exit curl_output http_code time_total size_download

  started="$(date +%s)"
  set +e
  curl_output="$(
    curl --noproxy '*' -sS \
      --connect-timeout 20 \
      --max-time "${REQUEST_TIMEOUT_SECONDS}" \
      -H "Content-Type: application/json" \
      -d "@${PAYLOAD}" \
      -o "${response}" \
      -w "%{http_code},%{time_total},%{size_download}" \
      "${ENDPOINT}" 2>"${error_log}"
  )"
  curl_exit=$?
  set -e
  ended="$(date +%s)"

  IFS=',' read -r http_code time_total size_download <<< "${curl_output:-000,0,0}"
  echo "${phase},${idx},${http_code:-000},${time_total:-0},${size_download:-0},${curl_exit},${started},${ended},${response},${error_log}" > "${meta}"
}

run_phase() {
  local phase="$1"
  local total="$2"
  local concurrency="$3"
  local active=0
  local i

  [ "${total}" -le 0 ] && return 0
  for i in $(seq 1 "${total}"); do
    run_request "${phase}" "${i}" &
    active=$((active + 1))
    if [ "${active}" -ge "${concurrency}" ]; then
      wait -n || true
      active=$((active - 1))
    fi
  done
  wait || true
}

write_summary() {
  echo "phase,index,http_code,time_total_sec,size_download_bytes,curl_exit,started_epoch,ended_epoch,response_file,error_file" > "${REQUESTS_CSV}"
  find "${TMP_DIR}" -maxdepth 1 -name '*.meta' -print0 | sort -z | xargs -0 cat >> "${REQUESTS_CSV}" 2>/dev/null || true

  python3 - "${REQUESTS_CSV}" "${HOST_METRICS_CSV}" "${DOCKER_STATS_JSONL}" "${DMESG_BEFORE}" "${DMESG_AFTER}" "${SUMMARY}" <<'PY'
import csv
import json
import math
import re
import sys
from collections import defaultdict

requests_csv, host_csv, docker_jsonl, dmesg_before, dmesg_after, summary_path = sys.argv[1:]

def percentile(values, pct):
    if not values:
        return None
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    rank = (len(values) - 1) * pct / 100
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (rank - lo)

def parse_bytes(text):
    if not text:
        return None
    match = re.search(r'([0-9.]+)\s*([KMGTPE]?i?B|B)', text)
    if not match:
        return None
    value = float(match.group(1))
    unit = match.group(2)
    factors = {
        "B": 1,
        "kB": 1000, "KB": 1000, "KiB": 1024,
        "MB": 1000**2, "MiB": 1024**2,
        "GB": 1000**3, "GiB": 1024**3,
        "TB": 1000**4, "TiB": 1024**4,
    }
    return value * factors.get(unit, 1)

def fmt_gib(value):
    if value is None:
        return "n/a"
    return f"{value / (1024**3):.2f} GiB"

rows = []
with open(requests_csv, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        rows.append(row)

measured = [r for r in rows if r["phase"] == "measured"]
success = [r for r in measured if r["http_code"] == "200" and r["curl_exit"] == "0"]
failed = [r for r in measured if r not in success]
latencies = [float(r["time_total_sec"]) for r in success]

host_rows = []
with open(host_csv, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        host_rows.append(row)

mem_available = [int(r["mem_available_kb"]) for r in host_rows if r.get("mem_available_kb")]
load1 = [float(r["load1"]) for r in host_rows if r.get("load1")]

docker = defaultdict(lambda: {"cpu": [], "mem_bytes": [], "mem_pct": []})
try:
    with open(docker_jsonl, encoding="utf-8") as f:
        for line in f:
            obj = json.loads(line)
            stat = obj.get("docker", {})
            name = stat.get("Name") or stat.get("Container") or "unknown"
            cpu = (stat.get("CPUPerc") or "").rstrip("%")
            mem_pct = (stat.get("MemPerc") or "").rstrip("%")
            mem_usage = (stat.get("MemUsage") or "").split("/")[0].strip()
            try:
                docker[name]["cpu"].append(float(cpu))
            except ValueError:
                pass
            try:
                docker[name]["mem_pct"].append(float(mem_pct))
            except ValueError:
                pass
            parsed = parse_bytes(mem_usage)
            if parsed is not None:
                docker[name]["mem_bytes"].append(parsed)
except FileNotFoundError:
    pass

before = set(open(dmesg_before, encoding="utf-8", errors="ignore").read().splitlines()) if dmesg_before else set()
after_lines = open(dmesg_after, encoding="utf-8", errors="ignore").read().splitlines() if dmesg_after else []
new_oom = [line for line in after_lines if line not in before]

lines = []
lines.append("LightOnOCR local benchmark summary")
lines.append("")
lines.append(f"measured_requests={len(measured)}")
lines.append(f"successful_requests={len(success)}")
lines.append(f"failed_requests={len(failed)}")
if latencies:
    lines.append(f"latency_min_sec={min(latencies):.3f}")
    lines.append(f"latency_avg_sec={sum(latencies) / len(latencies):.3f}")
    lines.append(f"latency_p50_sec={percentile(latencies, 50):.3f}")
    lines.append(f"latency_p95_sec={percentile(latencies, 95):.3f}")
    lines.append(f"latency_p99_sec={percentile(latencies, 99):.3f}")
    lines.append(f"latency_max_sec={max(latencies):.3f}")
else:
    lines.append("latency=n/a")

if mem_available:
    lines.append("")
    lines.append(f"host_mem_available_start={fmt_gib(mem_available[0] * 1024)}")
    lines.append(f"host_mem_available_min={fmt_gib(min(mem_available) * 1024)}")
    lines.append(f"host_mem_available_end={fmt_gib(mem_available[-1] * 1024)}")
if load1:
    lines.append(f"host_load1_max={max(load1):.2f}")

if docker:
    lines.append("")
    for name, values in sorted(docker.items()):
        lines.append(f"container={name}")
        if values["cpu"]:
            lines.append(f"  cpu_max_pct={max(values['cpu']):.2f}")
        if values["mem_pct"]:
            lines.append(f"  mem_max_pct={max(values['mem_pct']):.2f}")
        if values["mem_bytes"]:
            lines.append(f"  mem_max={fmt_gib(max(values['mem_bytes']))}")

lines.append("")
lines.append(f"new_oom_lines={len(new_oom)}")
for line in new_oom[-10:]:
    lines.append(f"  {line}")

with open(summary_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
}

echo "output_dir=${TMP_DIR}"
echo "input=${INPUT_PATH}"
render_input >/dev/null
build_payload

dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_BEFORE}" || true

sample_metrics &
sampler_pid=$!
trap 'kill "${sampler_pid}" >/dev/null 2>&1 || true' EXIT

echo "warmup_requests=${WARMUP_REQUESTS}"
run_phase warmup "${WARMUP_REQUESTS}" 1

echo "measured_requests=${REQUESTS} concurrency=${CONCURRENCY}"
run_phase measured "${REQUESTS}" "${CONCURRENCY}"

kill "${sampler_pid}" >/dev/null 2>&1 || true
trap - EXIT

dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_AFTER}" || true
write_summary

echo ""
echo "Artifacts:"
echo "  ${SUMMARY}"
echo "  ${REQUESTS_CSV}"
echo "  ${HOST_METRICS_CSV}"
echo "  ${DOCKER_STATS_JSONL}"
