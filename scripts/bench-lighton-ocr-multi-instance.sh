#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
PAGE_INDEX="${2:-0}"

IMAGE="${IMAGE:-lighton-ocr-vllm-cpu:sebi-20260714}"
PREFIX="${PREFIX:-lighton-ocr-vllm-cpu-exp}"
INSTANCE_COUNTS="${INSTANCE_COUNTS:-1 2 4}"
CORES_PER_INSTANCE="${CORES_PER_INSTANCE:-8}"
CPUSET_START="${CPUSET_START:-0}"
BASE_PORT="${BASE_PORT:-8010}"
WARMUP_ROUNDS="${WARMUP_ROUNDS:-1}"
MEASURED_ROUNDS="${MEASURED_ROUNDS:-1}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-900}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-false}"
TMP_DIR="${TMP_DIR:-/tmp/lighton-ocr-multi-bench-$(date +%Y%m%d-%H%M%S)}"

MODEL="${MODEL:-lightonai/LightOnOCR-2-1B-bbox}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
VLLM_DTYPE="${VLLM_DTYPE:-bfloat16}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
VLLM_CPU_KVCACHE_SPACE="${VLLM_CPU_KVCACHE_SPACE:-16}"

if [ -z "${INPUT_PATH}" ] || [ ! -f "${INPUT_PATH}" ]; then
  echo "usage: $0 /path/to/file.pdf-or-image [zero_based_page_index]" >&2
  echo "env: INSTANCE_COUNTS='1 2 4' CORES_PER_INSTANCE=8 WARMUP_ROUNDS=1 MEASURED_ROUNDS=1 MAX_TOKENS=4096" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if ! [[ "${CORES_PER_INSTANCE}" =~ ^[0-9]+$ ]] || [ "${CORES_PER_INSTANCE}" -lt 1 ]; then
  echo "CORES_PER_INSTANCE must be a positive integer" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "image not found: ${IMAGE}" >&2
  exit 1
fi

mkdir -p "${TMP_DIR}/responses" "${TMP_DIR}/errors" "${TMP_DIR}/payloads"
IMAGE_PATH="${TMP_DIR}/page.png"
PAYLOAD="${TMP_DIR}/payloads/request.json"
RESULTS_CSV="${TMP_DIR}/requests.csv"
HOST_METRICS_CSV="${TMP_DIR}/host_metrics.csv"
DOCKER_STATS_JSONL="${TMP_DIR}/docker_stats.jsonl"
SUMMARY="${TMP_DIR}/summary.txt"
DMESG_BEFORE="${TMP_DIR}/dmesg_oom_before.txt"
DMESG_AFTER="${TMP_DIR}/dmesg_oom_after.txt"

echo "output_dir=${TMP_DIR}"
echo "image=${IMAGE}"
echo "instance_counts=${INSTANCE_COUNTS}"
echo "cores_per_instance=${CORES_PER_INSTANCE}"

echo "experiment_instance_count,ts_epoch,ts_iso,mem_total_kb,mem_available_kb,mem_free_kb,swap_total_kb,swap_free_kb,load1,load5,load15,root_avail_kb,data_avail_kb,docker_avail_kb" > "${HOST_METRICS_CSV}"
: > "${DOCKER_STATS_JSONL}"

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
        page_one_based=$((PAGE_INDEX + 1))
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

container_name() {
  printf "%s-%s" "${PREFIX}" "$1"
}

container_port() {
  printf "%s" "$((BASE_PORT + $1))"
}

container_cpuset() {
  local index="$1"
  local start end
  start=$((CPUSET_START + (index - 1) * CORES_PER_INSTANCE))
  end=$((start + CORES_PER_INSTANCE - 1))
  printf "%s-%s" "${start}" "${end}"
}

cleanup_containers() {
  local max_count="${1:-16}"
  local i name
  for i in $(seq 1 "${max_count}"); do
    name="$(container_name "${i}")"
    docker rm -f "${name}" >/dev/null 2>&1 || true
  done
}

disk_avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

sample_metrics() {
  local names="$1"
  local experiment_instance_count="$2"
  while true; do
    local ts iso mem_total mem_available mem_free swap_total swap_free load1 load5 load15 root_avail data_avail docker_avail stats
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
    echo "${experiment_instance_count},${ts},${iso},${mem_total},${mem_available},${mem_free},${swap_total},${swap_free},${load1},${load5},${load15},${root_avail:-},${data_avail:-},${docker_avail:-}" >> "${HOST_METRICS_CSV}"

    stats="$(docker stats --no-stream --format '{{json .}}' ${names} 2>/dev/null || true)"
    if [ -n "${stats}" ]; then
      while IFS= read -r line; do
        [ -n "${line}" ] && printf '{"experiment_instance_count":%s,"ts_epoch":%s,"ts_iso":"%s","docker":%s}\n' "${experiment_instance_count}" "${ts}" "${iso}" "${line}" >> "${DOCKER_STATS_JSONL}"
      done <<< "${stats}"
    fi
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

start_instances() {
  local count="$1"
  local i name port cpuset
  cleanup_containers "${count}"

  for i in $(seq 1 "${count}"); do
    name="$(container_name "${i}")"
    port="$(container_port "${i}")"
    cpuset="$(container_cpuset "${i}")"
    echo "starting name=${name} port=${port} cpuset=${cpuset}"
    docker run -d \
      --name "${name}" \
      --network xyne \
      --cpuset-cpus "${cpuset}" \
      --cpus "${CORES_PER_INSTANCE}" \
      --shm-size 8g \
      --cap-add SYS_NICE \
      --security-opt seccomp=unconfined \
      -p "${port}:8000" \
      -v "$(pwd)/scripts/lighton-ocr-vllm-cpu-entrypoint.sh:/usr/local/bin/lighton-ocr-vllm-cpu-entrypoint.sh:ro" \
      -e MODEL_PATH=/models/lighton-ocr \
      -e SERVED_MODEL_NAME="${MODEL}" \
      -e VLLM_DTYPE="${VLLM_DTYPE}" \
      -e VLLM_CPU_KVCACHE_SPACE="${VLLM_CPU_KVCACHE_SPACE}" \
      -e VLLM_CPU_NUM_OF_RESERVED_CPU=1 \
      -e VLLM_CPU_OMP_THREADS_BIND="${cpuset}" \
      -e MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
      -e MAX_NUM_SEQS="${MAX_NUM_SEQS}" \
      -e MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS}" \
      -e 'LIMIT_MM_PER_PROMPT={"image":1}' \
      -e TRANSFORMERS_OFFLINE=1 \
      -e HF_HUB_OFFLINE=1 \
      "${IMAGE}" >/dev/null
  done
}

wait_for_instances() {
  local count="$1"
  local i port deadline
  deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  for i in $(seq 1 "${count}"); do
    port="$(container_port "${i}")"
    echo "waiting_for_health name=$(container_name "${i}") url=http://localhost:${port}/health"
    until curl --noproxy '*' -fsS "http://localhost:${port}/health" >/dev/null 2>&1; do
      if [ "${SECONDS}" -ge "${deadline}" ]; then
        echo "health timeout for $(container_name "${i}")" >&2
        docker logs --tail 100 "$(container_name "${i}")" >&2 || true
        exit 1
      fi
      sleep 5
    done
  done
}

run_request() {
  local phase="$1"
  local instance_count="$2"
  local round="$3"
  local instance="$4"
  local port response error_log meta started ended curl_exit curl_output http_code time_total size_download

  port="$(container_port "${instance}")"
  response="${TMP_DIR}/responses/${phase}_n${instance_count}_r${round}_i${instance}.json"
  error_log="${TMP_DIR}/errors/${phase}_n${instance_count}_r${round}_i${instance}.err"
  meta="${TMP_DIR}/${phase}_n${instance_count}_r${round}_i${instance}.meta"

  echo "request_start phase=${phase} instances=${instance_count} round=${round} instance=${instance} port=${port} ts=$(date -Is)" >&2
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
      "http://localhost:${port}/v1/chat/completions" 2>"${error_log}"
  )"
  curl_exit=$?
  set -e
  ended="$(date +%s)"
  IFS=',' read -r http_code time_total size_download <<< "${curl_output:-000,0,0}"
  echo "${phase},${instance_count},${round},${instance},$(container_name "${instance}"),${port},${http_code:-000},${time_total:-0},${size_download:-0},${curl_exit},${started},${ended},${response},${error_log}" > "${meta}"
  echo "request_done phase=${phase} instances=${instance_count} round=${round} instance=${instance} http=${http_code:-000} curl_exit=${curl_exit} time_total_sec=${time_total:-0} ts=$(date -Is)" >&2
}

run_rounds() {
  local phase="$1"
  local instance_count="$2"
  local rounds="$3"
  local round instance pid
  local pids=()

  [ "${rounds}" -le 0 ] && return 0
  for round in $(seq 1 "${rounds}"); do
    pids=()
    for instance in $(seq 1 "${instance_count}"); do
      run_request "${phase}" "${instance_count}" "${round}" "${instance}" &
      pids+=("$!")
    done
    for pid in "${pids[@]}"; do
      wait "${pid}" || true
    done
  done
}

write_summary() {
  echo "phase,instance_count,round,instance,container,port,http_code,time_total_sec,size_download_bytes,curl_exit,started_epoch,ended_epoch,response_file,error_file" > "${RESULTS_CSV}"
  find "${TMP_DIR}" -maxdepth 1 -name '*.meta' -print0 | sort -z | xargs -0 cat >> "${RESULTS_CSV}" 2>/dev/null || true

  python3 - "${RESULTS_CSV}" "${HOST_METRICS_CSV}" "${DOCKER_STATS_JSONL}" "${DMESG_BEFORE}" "${DMESG_AFTER}" "${SUMMARY}" <<'PY'
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
    rows = list(csv.DictReader(f))

host_rows = []
with open(host_csv, newline="", encoding="utf-8") as f:
    host_rows = list(csv.DictReader(f))
mem_available = [int(r["mem_available_kb"]) for r in host_rows if r.get("mem_available_kb")]
load1 = [float(r["load1"]) for r in host_rows if r.get("load1")]

docker = defaultdict(lambda: {"cpu": [], "mem_bytes": [], "mem_pct": []})
try:
    with open(docker_jsonl, encoding="utf-8") as f:
        for line in f:
            obj = json.loads(line)
            stat = obj.get("docker", {})
            count = obj.get("experiment_instance_count", "unknown")
            raw_name = stat.get("Name") or stat.get("Container") or "unknown"
            name = f"n{count}/{raw_name}"
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

before = set(open(dmesg_before, encoding="utf-8", errors="ignore").read().splitlines())
after_lines = open(dmesg_after, encoding="utf-8", errors="ignore").read().splitlines()
new_oom = [line for line in after_lines if line not in before]

lines = []
lines.append("LightOnOCR multi-instance benchmark summary")
lines.append("")

for count in sorted({int(r["instance_count"]) for r in rows if r["phase"] == "measured"}):
    measured = [r for r in rows if r["phase"] == "measured" and int(r["instance_count"]) == count]
    success = [r for r in measured if r["http_code"] == "200" and r["curl_exit"] == "0"]
    failed = [r for r in measured if r not in success]
    latencies = [float(r["time_total_sec"]) for r in success]
    starts = [int(r["started_epoch"]) for r in measured]
    ends = [int(r["ended_epoch"]) for r in measured]
    wall = max(ends) - min(starts) if starts and ends else 0
    pages_per_min = (len(success) / wall * 60) if wall else 0
    lines.append(f"instance_count={count}")
    lines.append(f"  measured_requests={len(measured)}")
    lines.append(f"  successful_requests={len(success)}")
    lines.append(f"  failed_requests={len(failed)}")
    lines.append(f"  measured_wall_sec={wall}")
    lines.append(f"  throughput_pages_per_min={pages_per_min:.3f}")
    if latencies:
        lines.append(f"  latency_avg_sec={sum(latencies) / len(latencies):.3f}")
        lines.append(f"  latency_p50_sec={percentile(latencies, 50):.3f}")
        lines.append(f"  latency_p95_sec={percentile(latencies, 95):.3f}")
        lines.append(f"  latency_max_sec={max(latencies):.3f}")
    lines.append("")

if mem_available:
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

max_instance_count() {
  local max=0 count
  for count in ${INSTANCE_COUNTS}; do
    [ "${count}" -gt "${max}" ] && max="${count}"
  done
  echo "${max}"
}

render_input >/dev/null
build_payload
dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_BEFORE}" || true

cleanup_containers "$(max_instance_count)"
if [ "${KEEP_CONTAINERS}" != "true" ]; then
  trap 'cleanup_containers "$(max_instance_count)"' EXIT
fi

for count in ${INSTANCE_COUNTS}; do
  echo ""
  echo "=== experiment instance_count=${count} cores_each=${CORES_PER_INSTANCE} ==="
  start_instances "${count}"
  wait_for_instances "${count}"

  names=""
  for i in $(seq 1 "${count}"); do
    names="${names} $(container_name "${i}")"
  done
  sample_metrics "${names}" "${count}" &
  sampler_pid=$!

  echo "warmup_rounds=${WARMUP_ROUNDS}"
  run_rounds warmup "${count}" "${WARMUP_ROUNDS}"

  echo "measured_rounds=${MEASURED_ROUNDS}"
  run_rounds measured "${count}" "${MEASURED_ROUNDS}"

  kill "${sampler_pid}" >/dev/null 2>&1 || true
  cleanup_containers "${count}"
done

dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_AFTER}" || true
write_summary

echo ""
echo "Artifacts:"
echo "  ${SUMMARY}"
echo "  ${RESULTS_CSV}"
echo "  ${HOST_METRICS_CSV}"
echo "  ${DOCKER_STATS_JSONL}"

if [ "${KEEP_CONTAINERS}" != "true" ]; then
  trap - EXIT
fi
