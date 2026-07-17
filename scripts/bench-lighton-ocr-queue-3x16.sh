#!/usr/bin/env bash
set -euo pipefail

INPUT_ROOT="${1:-}"
PAGE_INDEX="${2:-0}"

if [ -z "${INPUT_ROOT}" ] || [ ! -e "${INPUT_ROOT}" ]; then
  echo "usage: $0 /path/to/pdf-image-or-directory [zero_based_pdf_page_index]" >&2
  echo "env: REQUESTS=15 MAX_FILES=15 WARMUP=true MAX_TOKENS=4096 CPUSET_START=0 KEEP_CONTAINERS=false" >&2
  exit 1
fi

if [ -d "${INPUT_ROOT}" ]; then
  INPUT_ROOT="$(cd "${INPUT_ROOT}" && pwd)"
else
  INPUT_ROOT="$(cd "$(dirname "${INPUT_ROOT}")" && pwd)/$(basename "${INPUT_ROOT}")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

IMAGE="${IMAGE:-lighton-ocr-vllm-cpu:sebi-20260714}"
MODEL="${MODEL:-lightonai/LightOnOCR-2-1B-bbox}"
MAX_FILES="${MAX_FILES:-15}"
REQUESTS="${REQUESTS:-15}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
WARMUP="${WARMUP:-true}"
CPUSET_START="${CPUSET_START:-0}"
BASE_PORT="${BASE_PORT:-8010}"
PREFIX="${PREFIX:-lighton-ocr-vllm-cpu-queue}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-900}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-false}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_DIR}/benchmark-results}"
RESULT_DIR="${TMP_DIR:-${RESULTS_ROOT}/lighton-ocr-queue-3x16-${RUN_ID}}"

if ! [[ "${MAX_FILES}" =~ ^[0-9]+$ ]] || [ "${MAX_FILES}" -lt 1 ]; then
  echo "MAX_FILES must be a positive integer" >&2
  exit 1
fi
if ! [[ "${REQUESTS}" =~ ^[0-9]+$ ]] || [ "${REQUESTS}" -lt 1 ]; then
  echo "REQUESTS must be a positive integer" >&2
  exit 1
fi
if ! [[ "${CPUSET_START}" =~ ^[0-9]+$ ]]; then
  echo "CPUSET_START must be a non-negative integer" >&2
  exit 1
fi
if ! [[ "${PAGE_INDEX}" =~ ^[0-9]+$ ]]; then
  echo "page index must be a non-negative integer" >&2
  exit 1
fi

for command_name in docker curl python3; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required" >&2
    exit 1
  }
done

mkdir -p \
  "${RESULT_DIR}/rendered" \
  "${RESULT_DIR}/payloads" \
  "${RESULT_DIR}/responses" \
  "${RESULT_DIR}/errors" \
  "${RESULT_DIR}/metadata" \
  "${RESULT_DIR}/queue/specs" \
  "${RESULT_DIR}/queue/pending" \
  "${RESULT_DIR}/queue/claimed"

exec > >(tee "${RESULT_DIR}/console.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

container_name() {
  printf '%s-%s' "${PREFIX}" "$1"
}

container_port() {
  printf '%s' "$((BASE_PORT + $1))"
}

container_cpuset() {
  local index="$1"
  local start=$((CPUSET_START + (index - 1) * 16))
  printf '%s-%s' "${start}" "$((start + 15))"
}

declare -a INPUTS=()
if [ -f "${INPUT_ROOT}" ]; then
  case "${INPUT_ROOT,,}" in
    *.pdf|*.png|*.jpg|*.jpeg|*.webp)
      absolute_input="$(cd "$(dirname "${INPUT_ROOT}")" && pwd)/$(basename "${INPUT_ROOT}")"
      for ((request_number = 1; request_number <= REQUESTS; request_number++)); do
        INPUTS+=("${absolute_input}")
      done
      ;;
    *)
      echo "unsupported input type: ${INPUT_ROOT}" >&2
      exit 1
      ;;
  esac
elif [ -d "${INPUT_ROOT}" ]; then
  while IFS= read -r -d '' input_path; do
    INPUTS+=("${input_path}")
    [ "${#INPUTS[@]}" -ge "${MAX_FILES}" ] && break
  done < <(
    find "${INPUT_ROOT}" -maxdepth 1 -type f \
      \( -iname '*.pdf' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
      -print0 | sort -z
  )
else
  echo "input must be a file or directory: ${INPUT_ROOT}" >&2
  exit 1
fi

if [ "${#INPUTS[@]}" -eq 0 ]; then
  echo "no supported PDF or image files found under ${INPUT_ROOT}" >&2
  exit 1
fi

cleanup_containers() {
  local index
  for index in 1 2 3; do
    docker rm -f "$(container_name "${index}")" >/dev/null 2>&1 || true
  done
}

sampler_pid=""
cleanup() {
  if [ -n "${sampler_pid}" ]; then
    kill "${sampler_pid}" >/dev/null 2>&1 || true
    wait "${sampler_pid}" >/dev/null 2>&1 || true
  fi
  if [ "${KEEP_CONTAINERS}" != "true" ]; then
    cleanup_containers
  fi
}
trap cleanup EXIT INT TERM

log "LightOnOCR queued benchmark: 3 containers x 16 logical CPUs"
if [ -f "${INPUT_ROOT}" ]; then
  log "Queued ${#INPUTS[@]} independent request(s) for the single input file"
else
  log "Selected ${#INPUTS[@]} distinct input file(s) from the directory"
fi
log "Each completed worker immediately claims the next queued request"
log "Result directory: ${RESULT_DIR}"

{
  echo "run_id=${RUN_ID}"
  echo "started_at=$(date -Is)"
  echo "input_root=${INPUT_ROOT}"
  echo "page_index=${PAGE_INDEX}"
  echo "image=${IMAGE}"
  echo "model=${MODEL}"
  echo "instance_count=3"
  echo "cores_per_instance=16"
  echo "cpu_sets=$(container_cpuset 1),$(container_cpuset 2),$(container_cpuset 3)"
  echo "queued_jobs=${#INPUTS[@]}"
  echo "single_file_requests=${REQUESTS}"
  echo "max_tokens=${MAX_TOKENS}"
  echo "warmup=${WARMUP}"
} > "${RESULT_DIR}/run-config.txt"

prepare_payload() {
  local job_id="$1"
  local input_path="$2"
  local rendered_path="${RESULT_DIR}/rendered/${job_id}.png"
  local payload_path="${RESULT_DIR}/payloads/${job_id}.json"

  case "${input_path,,}" in
    *.pdf)
      if python3 -c 'import pypdfium2' >/dev/null 2>&1; then
        python3 - "${input_path}" "${PAGE_INDEX}" "${rendered_path}" <<'PY'
import sys
from pathlib import Path
import pypdfium2 as pdfium

pdf_path, page_index, output_path = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
pdf = pdfium.PdfDocument(pdf_path)
if page_index >= len(pdf):
    raise SystemExit(f"page index {page_index} is outside document with {len(pdf)} pages: {pdf_path}")
page = pdf[page_index]
width, height = page.get_size()
scale = 1540 / max(width, height)
page.render(scale=scale).to_pil().convert("RGB").save(output_path)
PY
      elif command -v pdftoppm >/dev/null 2>&1; then
        local one_based_page=$((PAGE_INDEX + 1))
        pdftoppm -png -f "${one_based_page}" -l "${one_based_page}" -singlefile -r 180 \
          "${input_path}" "${RESULT_DIR}/rendered/${job_id}"
      else
        echo "PDF input requires pypdfium2 or pdftoppm" >&2
        return 1
      fi
      ;;
    *.png|*.jpg|*.jpeg|*.webp)
      cp "${input_path}" "${rendered_path}"
      ;;
  esac

  python3 - "${payload_path}" "${MODEL}" "${rendered_path}" "${MAX_TOKENS}" <<'PY'
import base64
import json
import sys

output_path, model, image_path, max_tokens = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(image_path, "rb") as image_file:
    image_data = base64.b64encode(image_file.read()).decode("ascii")
payload = {
    "model": model,
    "messages": [{
        "role": "user",
        "content": [{
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{image_data}"},
        }],
    }],
    "max_tokens": max_tokens,
    "temperature": 0.0,
}
with open(output_path, "w", encoding="utf-8") as output_file:
    json.dump(payload, output_file)
PY

  printf '%s\t%s\n' "${input_path}" "${payload_path}" > "${RESULT_DIR}/queue/specs/${job_id}.tsv"
}

log "Preparing request payloads before timed execution"
job_number=0
for input_path in "${INPUTS[@]}"; do
  job_number=$((job_number + 1))
  job_id="$(printf '%04d' "${job_number}")"
  log "PREPARE job=${job_id} file=${input_path}"
  prepare_payload "${job_id}" "${input_path}"
done
log "Prepared ${job_number} queued job(s)"

docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
  echo "Docker image is not loaded: ${IMAGE}" >&2
  exit 1
}
docker network inspect xyne >/dev/null 2>&1 || docker network create xyne >/dev/null

cleanup_containers

start_container() {
  local worker_id="$1"
  local name port cpuset
  name="$(container_name "${worker_id}")"
  port="$(container_port "${worker_id}")"
  cpuset="$(container_cpuset "${worker_id}")"
  log "START worker=${worker_id} container=${name} port=${port} cpuset=${cpuset}"

  docker run -d \
    --name "${name}" \
    --network xyne \
    --cpuset-cpus "${cpuset}" \
    --cpus 16 \
    --shm-size 8g \
    --cap-add SYS_NICE \
    --security-opt seccomp=unconfined \
    -p "${port}:8000" \
    -v "${REPO_DIR}/scripts/lighton-ocr-vllm-cpu-entrypoint.sh:/usr/local/bin/lighton-ocr-vllm-cpu-entrypoint.sh:ro" \
    -e MODEL_PATH=/models/lighton-ocr \
    -e SERVED_MODEL_NAME="${MODEL}" \
    -e VLLM_DTYPE="${VLLM_DTYPE:-bfloat16}" \
    -e VLLM_CPU_KVCACHE_SPACE="${VLLM_CPU_KVCACHE_SPACE:-16}" \
    -e VLLM_CPU_NUM_OF_RESERVED_CPU=1 \
    -e VLLM_CPU_OMP_THREADS_BIND="${cpuset}" \
    -e MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}" \
    -e MAX_NUM_SEQS=1 \
    -e MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}" \
    -e 'LIMIT_MM_PER_PROMPT={"image":1}' \
    -e TRANSFORMERS_OFFLINE=1 \
    -e HF_HUB_OFFLINE=1 \
    "${IMAGE}" >/dev/null
}

for worker_id in 1 2 3; do
  start_container "${worker_id}"
done

wait_for_container() {
  local worker_id="$1"
  local name="$(container_name "${worker_id}")"
  local port="$(container_port "${worker_id}")"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  log "HEALTH_WAIT worker=${worker_id} container=${name} url=http://localhost:${port}/health"
  until curl --noproxy '*' -fsS "http://localhost:${port}/health" >/dev/null 2>&1; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      log "HEALTH_TIMEOUT worker=${worker_id} container=${name}"
      docker logs --tail 200 "${name}" >&2 || true
      return 1
    fi
    sleep 5
  done
  log "HEALTH_OK worker=${worker_id} container=${name}"
}

for worker_id in 1 2 3; do
  wait_for_container "${worker_id}"
done

HOST_METRICS_CSV="${RESULT_DIR}/host_metrics.csv"
DOCKER_STATS_JSONL="${RESULT_DIR}/docker_stats.jsonl"
DMESG_BEFORE="${RESULT_DIR}/dmesg_oom_before.txt"
DMESG_AFTER="${RESULT_DIR}/dmesg_oom_after.txt"

disk_avail_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

sample_metrics() {
  echo "ts_epoch,ts_iso,mem_total_kb,mem_available_kb,mem_free_kb,swap_total_kb,swap_free_kb,load1,load5,load15,root_avail_kb,data_avail_kb,docker_avail_kb" > "${HOST_METRICS_CSV}"
  : > "${DOCKER_STATS_JSONL}"
  while true; do
    local ts iso mem_total mem_available mem_free swap_total swap_free load1 load5 load15
    local root_avail data_avail docker_avail stats
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

    stats="$(docker stats --no-stream --format '{{json .}}' \
      "$(container_name 1)" "$(container_name 2)" "$(container_name 3)" 2>/dev/null || true)"
    while IFS= read -r line; do
      [ -n "${line}" ] && printf '{"ts_epoch":%s,"ts_iso":"%s","docker":%s}\n' \
        "${ts}" "${iso}" "${line}" >> "${DOCKER_STATS_JSONL}"
    done <<< "${stats}"
    sleep "${SAMPLE_INTERVAL_SECONDS}"
  done
}

dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_BEFORE}" || true
sample_metrics &
sampler_pid=$!

warmup_request() {
  local worker_id="$1"
  local port="$(container_port "${worker_id}")"
  local response="${RESULT_DIR}/responses/warmup_worker_${worker_id}.json"
  local error_file="${RESULT_DIR}/errors/warmup_worker_${worker_id}.err"
  local payload="${RESULT_DIR}/payloads/0001.json"
  local result curl_exit http_code time_total
  log "WARMUP_START worker=${worker_id} port=${port}"
  set +e
  result="$(curl --noproxy '*' -sS --connect-timeout 20 --max-time "${REQUEST_TIMEOUT_SECONDS}" \
    -H 'Content-Type: application/json' -d "@${payload}" -o "${response}" \
    -w '%{http_code},%{time_total}' "http://localhost:${port}/v1/chat/completions" 2>"${error_file}")"
  curl_exit=$?
  set -e
  IFS=',' read -r http_code time_total <<< "${result:-000,0}"
  log "WARMUP_DONE worker=${worker_id} http=${http_code:-000} curl_exit=${curl_exit} latency_sec=${time_total:-0}"
}

if [ "${WARMUP}" = "true" ]; then
  log "Starting one concurrent warm-up request per container"
  warmup_pids=()
  for worker_id in 1 2 3; do
    warmup_request "${worker_id}" &
    warmup_pids+=("$!")
  done
  for warmup_pid in "${warmup_pids[@]}"; do
    wait "${warmup_pid}"
  done
  log "All warm-up requests completed"
fi

cp "${RESULT_DIR}/queue/specs/"*.tsv "${RESULT_DIR}/queue/pending/"

claim_next_job() {
  local pending_file job_id claim_dir
  for pending_file in "${RESULT_DIR}/queue/pending/"*.tsv; do
    [ -f "${pending_file}" ] || return 1
    job_id="$(basename "${pending_file}" .tsv)"
    claim_dir="${RESULT_DIR}/queue/claimed/${job_id}"
    if mkdir "${claim_dir}" 2>/dev/null; then
      mv "${pending_file}" "${claim_dir}/job.tsv"
      printf '%s' "${job_id}"
      return 0
    fi
  done
  return 1
}

run_job() {
  local worker_id="$1"
  local job_id="$2"
  local spec="${RESULT_DIR}/queue/claimed/${job_id}/job.tsv"
  local input_path payload_path name port response error_file meta
  local started_epoch ended_epoch result curl_exit http_code time_total size_download
  IFS=$'\t' read -r input_path payload_path < "${spec}"
  name="$(container_name "${worker_id}")"
  port="$(container_port "${worker_id}")"
  response="${RESULT_DIR}/responses/job_${job_id}_worker_${worker_id}.json"
  error_file="${RESULT_DIR}/errors/job_${job_id}_worker_${worker_id}.err"
  meta="${RESULT_DIR}/metadata/job_${job_id}.tsv"

  log "JOB_START worker=${worker_id} container=${name} job=${job_id} file=${input_path} port=${port}"
  started_epoch="$(date +%s)"
  set +e
  result="$(curl --noproxy '*' -sS --connect-timeout 20 --max-time "${REQUEST_TIMEOUT_SECONDS}" \
    -H 'Content-Type: application/json' -d "@${payload_path}" -o "${response}" \
    -w '%{http_code},%{time_total},%{size_download}' \
    "http://localhost:${port}/v1/chat/completions" 2>"${error_file}")"
  curl_exit=$?
  set -e
  ended_epoch="$(date +%s)"
  IFS=',' read -r http_code time_total size_download <<< "${result:-000,0,0}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${job_id}" "${worker_id}" "${name}" "${input_path}" "${http_code:-000}" \
    "${curl_exit}" "${time_total:-0}" "${size_download:-0}" "${started_epoch}" \
    "${ended_epoch}" "${response}" "${error_file}" > "${meta}"
  log "JOB_DONE worker=${worker_id} job=${job_id} http=${http_code:-000} curl_exit=${curl_exit} latency_sec=${time_total:-0}; claiming next job"
}

worker_loop() {
  local worker_id="$1"
  local job_id processed=0
  log "WORKER_READY worker=${worker_id} container=$(container_name "${worker_id}") cpuset=$(container_cpuset "${worker_id}")"
  while job_id="$(claim_next_job)"; do
    processed=$((processed + 1))
    log "JOB_CLAIM worker=${worker_id} job=${job_id} worker_job_number=${processed}"
    run_job "${worker_id}" "${job_id}"
  done
  log "WORKER_DRAINED worker=${worker_id} completed_jobs=${processed}; queue empty"
}

log "QUEUE_START queued_jobs=${#INPUTS[@]} active_workers=3"
queue_started_epoch="$(date +%s)"
worker_pids=()
for worker_id in 1 2 3; do
  worker_loop "${worker_id}" &
  worker_pids+=("$!")
done
for worker_pid in "${worker_pids[@]}"; do
  wait "${worker_pid}"
done
queue_ended_epoch="$(date +%s)"
log "QUEUE_DRAINED wall_sec=$((queue_ended_epoch - queue_started_epoch))"

kill "${sampler_pid}" >/dev/null 2>&1 || true
wait "${sampler_pid}" >/dev/null 2>&1 || true
sampler_pid=""
dmesg -T 2>/dev/null | egrep -i 'oom|killed process|out of memory' > "${DMESG_AFTER}" || true

python3 - "${RESULT_DIR}" <<'PY'
import csv
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

root = Path(sys.argv[1])
fields = [
    "job_id", "worker_id", "container", "input_file", "http_code", "curl_exit",
    "latency_sec", "size_download_bytes", "started_epoch", "ended_epoch",
    "response_file", "error_file",
]
rows = []
for path in sorted((root / "metadata").glob("job_*.tsv")):
    values = path.read_text(encoding="utf-8").rstrip("\n").split("\t")
    row = dict(zip(fields, values))
    row.update(prompt_tokens="", completion_tokens="", total_tokens="", finish_reason="")
    try:
        response = json.loads(Path(row["response_file"]).read_text(encoding="utf-8"))
        usage = response.get("usage") or {}
        row["prompt_tokens"] = usage.get("prompt_tokens", "")
        row["completion_tokens"] = usage.get("completion_tokens", "")
        row["total_tokens"] = usage.get("total_tokens", "")
        choices = response.get("choices") or []
        row["finish_reason"] = choices[0].get("finish_reason", "") if choices else ""
    except Exception:
        pass
    rows.append(row)

output_fields = fields + ["prompt_tokens", "completion_tokens", "total_tokens", "finish_reason"]
with (root / "requests.csv").open("w", newline="", encoding="utf-8") as output:
    writer = csv.DictWriter(output, fieldnames=output_fields)
    writer.writeheader()
    writer.writerows(rows)

successful = [r for r in rows if r["http_code"] == "200" and r["curl_exit"] == "0"]
latencies = [float(r["latency_sec"]) for r in successful]
starts = [int(r["started_epoch"]) for r in rows]
ends = [int(r["ended_epoch"]) for r in rows]
wall = max(ends) - min(starts) if starts and ends else 0

def percentile(values, fraction):
    if not values:
        return 0.0
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return values[lower]
    return values[lower] + (values[upper] - values[lower]) * (position - lower)

by_worker = defaultdict(list)
for row in rows:
    by_worker[row["worker_id"]].append(row)

lines = ["LightOnOCR dynamic-queue benchmark summary", ""]
lines.append(f"queued_files={len(rows)}")
lines.append(f"successful_files={len(successful)}")
lines.append(f"failed_files={len(rows) - len(successful)}")
lines.append(f"queue_wall_sec={wall}")
lines.append(f"throughput_pages_per_min={(len(successful) / wall * 60) if wall else 0:.3f}")
if latencies:
    lines.append(f"latency_avg_sec={statistics.mean(latencies):.3f}")
    lines.append(f"latency_p50_sec={percentile(latencies, 0.50):.3f}")
    lines.append(f"latency_p95_sec={percentile(latencies, 0.95):.3f}")
    lines.append(f"latency_max_sec={max(latencies):.3f}")

for worker_id in sorted(by_worker, key=int):
    worker_rows = by_worker[worker_id]
    worker_success = [r for r in worker_rows if r["http_code"] == "200" and r["curl_exit"] == "0"]
    worker_latencies = [float(r["latency_sec"]) for r in worker_success]
    lines.extend(["", f"worker={worker_id}"])
    lines.append(f"  assigned_files={len(worker_rows)}")
    lines.append(f"  successful_files={len(worker_success)}")
    if worker_latencies:
        lines.append(f"  latency_avg_sec={statistics.mean(worker_latencies):.3f}")
        lines.append(f"  busy_time_sec={sum(worker_latencies):.3f}")

host_path = root / "host_metrics.csv"
if host_path.exists():
    with host_path.open(newline="", encoding="utf-8") as source:
        host_rows = list(csv.DictReader(source))
    available = [int(r["mem_available_kb"]) for r in host_rows if r.get("mem_available_kb")]
    load1 = [float(r["load1"]) for r in host_rows if r.get("load1")]
    if available:
        lines.extend(["", f"host_mem_available_min_gib={min(available) / 1024 / 1024:.2f}"])
    if load1:
        lines.append(f"host_load1_max={max(load1):.2f}")

before_path, after_path = root / "dmesg_oom_before.txt", root / "dmesg_oom_after.txt"
before = set(before_path.read_text(encoding="utf-8", errors="ignore").splitlines()) if before_path.exists() else set()
after = after_path.read_text(encoding="utf-8", errors="ignore").splitlines() if after_path.exists() else []
new_oom = [line for line in after if line not in before]
lines.append(f"new_oom_lines={len(new_oom)}")

(root / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines))
PY

echo "finished_at=$(date -Is)" >> "${RESULT_DIR}/run-config.txt"

log "Artifacts:"
log "  summary=${RESULT_DIR}/summary.txt"
log "  requests=${RESULT_DIR}/requests.csv"
log "  responses=${RESULT_DIR}/responses/"
log "  host_metrics=${RESULT_DIR}/host_metrics.csv"
log "  docker_metrics=${RESULT_DIR}/docker_stats.jsonl"
log "  console=${RESULT_DIR}/console.log"

if [ "${KEEP_CONTAINERS}" != "true" ]; then
  cleanup_containers
fi
trap - EXIT INT TERM
