"""Concurrency benchmark for the deployed LightOnOCR chat-completions endpoint."""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import statistics
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from config import Settings  # noqa: E402
from lighton_client import (  # noqa: E402
    LightOnClient,
    LightOnClientConfig,
    _clean_response,
    _extract_content,
)
from renderer import SUPPORTED_SUFFIXES, stream_rendered_pages  # noqa: E402

DEFAULT_CONCURRENCY = "1,2,4,8,12,16"
PROJECTION_HOURS = (8, 10, 12, 24)
HTTP_SERVER_ERROR_MIN = 500
NVIDIA_SMI_FIELD_COUNT = 3
STABLE_SUCCESS_RATE = 0.99
SATURATION_THROUGHPUT_IMPROVEMENT_PERCENT = 5
SATURATION_P95_LATENCY_INCREASE_PERCENT = 25
OOM_MARKERS = (
    "out of memory",
    "oom",
    "cuda error",
    "cuda out of memory",
    "memory allocation",
)


@dataclass(frozen=True)
class PageInput:
    id: str
    image_path: str
    source_path: str
    source_name: str
    page_number: int


@dataclass
class GpuSample:
    timestamp: float
    utilization_percent: float
    memory_used_mb: float
    memory_total_mb: float


@dataclass
class RequestResult:
    page_id: str
    source_name: str
    page_number: int
    ok: bool
    latency_seconds: float
    failure_type: str | None = None
    status_code: int | None = None
    error: str | None = None


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _float_env(name: str, default: float) -> float:
    raw = _env(name)
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def parse_concurrency(raw: str) -> list[int]:
    values: list[int] = []
    for raw_part in raw.split(","):
        part = raw_part.strip()
        if not part:
            continue
        value = int(part)
        if value < 1:
            raise ValueError("concurrency values must be positive")
        values.append(value)
    if not values:
        raise ValueError("at least one concurrency value is required")
    return values


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo)


def discover_files(input_dir: Path) -> list[Path]:
    if not input_dir.is_dir():
        raise ValueError(f"input path is not a directory: {input_dir}")
    files = [
        path
        for path in sorted(input_dir.rglob("*"))
        if path.is_file() and path.suffix.lower() in SUPPORTED_SUFFIXES
    ]
    if not files:
        supported = ", ".join(sorted(SUPPORTED_SUFFIXES))
        raise ValueError(f"no supported files found in {input_dir}; supported: {supported}")
    return files


async def render_dataset(
    input_dir: Path,
    *,
    settings: Settings,
    output_dir: Path,
    max_pages: int | None,
) -> list[PageInput]:
    pages: list[PageInput] = []
    files = discover_files(input_dir)
    for file_path in files:
        async for page in stream_rendered_pages(
            str(file_path),
            filename=file_path.name,
            render_max_dim=settings.render_max_dim,
            pdf_render_dpi=settings.pdf_render_dpi,
            max_pages=settings.max_pages,
            queue_size=max(1, settings.lighton_concurrency),
            office_convert_timeout_seconds=settings.office_convert_timeout_seconds,
            text_page_width=settings.text_page_width,
            text_page_height=settings.text_page_height,
            text_font_size=settings.text_font_size,
            text_margin=settings.text_margin,
        ):
            page_id = f"page-{len(pages) + 1:06d}"
            image_path = output_dir / f"{page_id}.jpg"
            page.image.save(image_path, format="JPEG", quality=settings.jpeg_quality)
            pages.append(
                PageInput(
                    id=page_id,
                    image_path=str(image_path),
                    source_path=str(file_path),
                    source_name=file_path.name,
                    page_number=page.page_number,
                )
            )
            if max_pages is not None and len(pages) >= max_pages:
                return pages
    return pages


def build_client(settings: Settings, concurrency: int) -> LightOnClient:
    return LightOnClient(
        LightOnClientConfig(
            endpoint_url=_env("LIGHTON_OCR_URL") or settings.lighton_url,
            model=_env("LIGHTON_OCR_MODEL") or settings.lighton_model,
            token=settings.lighton_access_token,
            timeout_seconds=_float_env(
                "LIGHTON_OCR_BENCHMARK_TIMEOUT",
                settings.lighton_timeout_seconds,
            ),
            max_output_tokens=_int_env(
                "LIGHTON_OCR_BENCHMARK_MAX_OUTPUT_TOKENS",
                settings.lighton_max_output_tokens,
            ),
            temperature=settings.lighton_temperature,
            concurrency=concurrency,
            retries=_int_env("LIGHTON_OCR_BENCHMARK_RETRIES", settings.lighton_retries),
            ssl_verify=settings.lighton_ssl_verify,
            image_max_dim=settings.image_max_dim,
            jpeg_quality=settings.jpeg_quality,
        )
    )


def classify_http_error(exc: httpx.HTTPStatusError) -> str:
    body = exc.response.text.lower()
    if any(marker in body for marker in OOM_MARKERS):
        return "oom"
    if exc.response.status_code >= HTTP_SERVER_ERROR_MIN:
        return "server_error"
    return "http_error"


async def send_ocr_request(
    client: LightOnClient,
    page: PageInput,
    prompt: str,
) -> RequestResult:
    headers = {"Content-Type": "application/json"}
    if client.config.token:
        headers["Authorization"] = f"Bearer {client.config.token}"

    try:
        with Image.open(page.image_path) as img:
            payload = client._payload(img.convert("RGB"), prompt)
    except Exception as exc:
        return RequestResult(
            page_id=page.id,
            source_name=page.source_name,
            page_number=page.page_number,
            ok=False,
            latency_seconds=0.0,
            failure_type="other_exception",
            error=f"payload preparation failed: {exc}",
        )

    start = time.perf_counter()
    last_exc: Exception | None = None
    for attempt in range(client.config.retries + 1):
        try:
            response = await client._client.post(
                client.config.endpoint_url,
                json=payload,
                headers=headers,
            )
            response.raise_for_status()
            _clean_response(_extract_content(response.json()), prompt)
            return RequestResult(
                page_id=page.id,
                source_name=page.source_name,
                page_number=page.page_number,
                ok=True,
                latency_seconds=time.perf_counter() - start,
                status_code=response.status_code,
            )
        except httpx.HTTPStatusError as exc:
            last_exc = exc
            if attempt >= client.config.retries:
                return RequestResult(
                    page_id=page.id,
                    source_name=page.source_name,
                    page_number=page.page_number,
                    ok=False,
                    latency_seconds=time.perf_counter() - start,
                    failure_type=classify_http_error(exc),
                    status_code=exc.response.status_code,
                    error=exc.response.text[:1000],
                )
        except httpx.TimeoutException as exc:
            last_exc = exc
            if attempt >= client.config.retries:
                return RequestResult(
                    page_id=page.id,
                    source_name=page.source_name,
                    page_number=page.page_number,
                    ok=False,
                    latency_seconds=time.perf_counter() - start,
                    failure_type="timeout",
                    error=str(exc),
                )
        except httpx.TransportError as exc:
            last_exc = exc
            if attempt >= client.config.retries:
                return RequestResult(
                    page_id=page.id,
                    source_name=page.source_name,
                    page_number=page.page_number,
                    ok=False,
                    latency_seconds=time.perf_counter() - start,
                    failure_type="connection_failure",
                    error=str(exc),
                )
        except Exception as exc:
            last_exc = exc
            if attempt >= client.config.retries:
                return RequestResult(
                    page_id=page.id,
                    source_name=page.source_name,
                    page_number=page.page_number,
                    ok=False,
                    latency_seconds=time.perf_counter() - start,
                    failure_type="other_exception",
                    error=str(exc),
                )
        await asyncio.sleep(min(2.0, 0.25 * (2**attempt)))

    return RequestResult(
        page_id=page.id,
        source_name=page.source_name,
        page_number=page.page_number,
        ok=False,
        latency_seconds=time.perf_counter() - start,
        failure_type="other_exception",
        error=str(last_exc) if last_exc else "request failed without an exception",
    )


async def run_warmup(
    pages: list[PageInput],
    *,
    settings: Settings,
    warmup_requests: int,
    prompt: str,
) -> None:
    if warmup_requests <= 0:
        return
    client = build_client(settings, min(warmup_requests, max(1, settings.lighton_concurrency)))
    try:
        for index in range(warmup_requests):
            await send_ocr_request(client, pages[index % len(pages)], prompt)
    finally:
        await client.close()


async def nvidia_smi_sample() -> list[GpuSample]:
    proc = await asyncio.create_subprocess_exec(
        "nvidia-smi",
        "--query-gpu=utilization.gpu,memory.used,memory.total",
        "--format=csv,noheader,nounits",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or "nvidia-smi failed")

    now = time.time()
    samples: list[GpuSample] = []
    for line in stdout.decode("utf-8", errors="replace").splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) != NVIDIA_SMI_FIELD_COUNT:
            continue
        samples.append(
            GpuSample(
                timestamp=now,
                utilization_percent=float(parts[0]),
                memory_used_mb=float(parts[1]),
                memory_total_mb=float(parts[2]),
            )
        )
    return samples


async def collect_gpu_samples(
    stop_event: asyncio.Event,
    *,
    interval_seconds: float,
    samples: list[GpuSample],
    unavailable: dict[str, str],
) -> None:
    while not stop_event.is_set():
        try:
            samples.extend(await nvidia_smi_sample())
        except Exception as exc:
            unavailable["reason"] = str(exc) or "nvidia-smi unavailable"
            return
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval_seconds)
        except asyncio.TimeoutError:
            continue


async def run_concurrency_level(
    pages: list[PageInput],
    *,
    settings: Settings,
    concurrency: int,
    prompt: str,
    collect_gpu: bool,
    gpu_interval_seconds: float,
) -> dict[str, Any]:
    queue: asyncio.Queue[PageInput] = asyncio.Queue(maxsize=concurrency)
    results: list[RequestResult] = []
    client = build_client(settings, concurrency)
    gpu_samples: list[GpuSample] = []
    gpu_unavailable: dict[str, str] = {}
    stop_gpu = asyncio.Event()
    gpu_task: asyncio.Task[None] | None = None

    async def producer() -> None:
        for page in pages:
            await queue.put(page)
        for _ in range(concurrency):
            await queue.put(PageInput("", "", "", "", -1))

    async def worker() -> None:
        while True:
            page = await queue.get()
            try:
                if page.page_number < 0:
                    return
                results.append(await send_ocr_request(client, page, prompt))
            finally:
                queue.task_done()

    if collect_gpu:
        gpu_task = asyncio.create_task(
            collect_gpu_samples(
                stop_gpu,
                interval_seconds=gpu_interval_seconds,
                samples=gpu_samples,
                unavailable=gpu_unavailable,
            )
        )

    start = time.perf_counter()
    try:
        workers = [asyncio.create_task(worker()) for _ in range(concurrency)]
        await producer()
        await queue.join()
        await asyncio.gather(*workers)
    finally:
        wall_clock = time.perf_counter() - start
        stop_gpu.set()
        if gpu_task is not None:
            await asyncio.gather(gpu_task, return_exceptions=True)
        await client.close()

    return summarize_run(
        concurrency=concurrency,
        total_pages=len(pages),
        wall_clock_seconds=wall_clock,
        results=results,
        gpu_samples=gpu_samples,
        gpu_unavailable_reason=gpu_unavailable.get("reason"),
    )


def summarize_failures(results: list[RequestResult]) -> dict[str, int]:
    summary = {
        "http_errors": 0,
        "timeouts": 0,
        "connection_failures": 0,
        "server_errors": 0,
        "oom_related": 0,
        "other_exceptions": 0,
    }
    for result in results:
        if result.ok:
            continue
        if result.failure_type == "http_error":
            summary["http_errors"] += 1
        elif result.failure_type == "timeout":
            summary["timeouts"] += 1
        elif result.failure_type == "connection_failure":
            summary["connection_failures"] += 1
        elif result.failure_type == "server_error":
            summary["server_errors"] += 1
        elif result.failure_type == "oom":
            summary["oom_related"] += 1
        else:
            summary["other_exceptions"] += 1
    return summary


def summarize_gpu(
    samples: list[GpuSample],
    unavailable_reason: str | None,
) -> dict[str, Any]:
    if unavailable_reason:
        return {
            "available": False,
            "reason": f"GPU metrics unavailable from benchmark host: {unavailable_reason}",
        }
    if not samples:
        return {
            "available": False,
            "reason": "GPU metrics unavailable from benchmark host",
        }
    return {
        "available": True,
        "sample_count": len(samples),
        "average_gpu_utilization_percent": statistics.fmean(
            sample.utilization_percent for sample in samples
        ),
        "maximum_gpu_utilization_percent": max(sample.utilization_percent for sample in samples),
        "average_gpu_memory_used_mb": statistics.fmean(sample.memory_used_mb for sample in samples),
        "maximum_gpu_memory_used_mb": max(sample.memory_used_mb for sample in samples),
        "gpu_memory_total_mb": max(sample.memory_total_mb for sample in samples),
    }


def projections(pages_per_hour: float) -> dict[str, Any]:
    capacity = {f"{hours}_hours": pages_per_hour * hours for hours in PROJECTION_HOURS}
    estimated_100k_hours = 100000 / pages_per_hour if pages_per_hour > 0 else None
    return {
        "label": "Projections based on measured sustained throughput.",
        "capacity_pages": capacity,
        "estimated_100k_hours": estimated_100k_hours,
    }


def summarize_run(
    *,
    concurrency: int,
    total_pages: int,
    wall_clock_seconds: float,
    results: list[RequestResult],
    gpu_samples: list[GpuSample],
    gpu_unavailable_reason: str | None,
) -> dict[str, Any]:
    success = [result for result in results if result.ok]
    failed = [result for result in results if not result.ok]
    latencies = [result.latency_seconds for result in results if result.latency_seconds > 0]
    successful_pages = len(success)
    pages_per_second = successful_pages / wall_clock_seconds if wall_clock_seconds > 0 else 0.0
    pages_per_minute = pages_per_second * 60
    pages_per_hour = pages_per_second * 3600
    return {
        "concurrency": concurrency,
        "total_requests": len(results),
        "successful_requests": len(success),
        "failed_requests": len(failed),
        "total_pages": total_pages,
        "successful_pages": successful_pages,
        "wall_clock_seconds": wall_clock_seconds,
        "pages_per_second": pages_per_second,
        "pages_per_minute": pages_per_minute,
        "pages_per_hour": pages_per_hour,
        "average_request_latency_seconds": statistics.fmean(latencies) if latencies else 0.0,
        "p50_latency_seconds": percentile(latencies, 0.50),
        "p95_latency_seconds": percentile(latencies, 0.95),
        "p99_latency_seconds": percentile(latencies, 0.99),
        "min_latency_seconds": min(latencies) if latencies else 0.0,
        "max_latency_seconds": max(latencies) if latencies else 0.0,
        "failures": summarize_failures(results),
        "failure_details": [asdict(result) for result in failed[:50]],
        "gpu": summarize_gpu(gpu_samples, gpu_unavailable_reason),
        "projections": projections(pages_per_hour),
    }


def best_observed_concurrency(runs: list[dict[str, Any]]) -> dict[str, Any]:
    stable = [
        run
        for run in runs
        if run["total_requests"] > 0
        and run["successful_requests"] / run["total_requests"] >= STABLE_SUCCESS_RATE
        and run["failures"]["oom_related"] == 0
    ]
    candidates = stable or runs
    best = max(candidates, key=lambda run: run["pages_per_second"])
    reasons = [f"Concurrency {best['concurrency']} had the best stable observed throughput."]

    ordered = sorted(runs, key=lambda run: run["concurrency"])
    for previous, current in zip(ordered, ordered[1:]):
        prev_tput = previous["pages_per_second"]
        curr_tput = current["pages_per_second"]
        if prev_tput <= 0:
            continue
        improvement = ((curr_tput - prev_tput) / prev_tput) * 100
        p95_change = (
            (
                (current["p95_latency_seconds"] - previous["p95_latency_seconds"])
                / previous["p95_latency_seconds"]
            )
            * 100
            if previous["p95_latency_seconds"] > 0
            else 0
        )
        if (
            improvement < SATURATION_THROUGHPUT_IMPROVEMENT_PERCENT
            and p95_change > SATURATION_P95_LATENCY_INCREASE_PERCENT
        ):
            reasons.append(
                f"Concurrency {current['concurrency']} improved throughput by "
                f"{improvement:.1f}% while p95 latency changed by {p95_change:.1f}%."
            )
        if current["failed_requests"] > previous["failed_requests"]:
            reasons.append(
                f"Concurrency {current['concurrency']} introduced/increased failures "
                f"({current['failed_requests']} failed requests)."
            )
    return {
        "best_observed_concurrency": best["concurrency"],
        "reason": reasons,
    }


def print_summary(runs: list[dict[str, Any]], conclusion: dict[str, Any]) -> None:
    headers = [
        "Concurrency",
        "Success",
        "Failed",
        "Wall Time",
        "Pages/sec",
        "Pages/min",
        "Avg Latency",
        "P95",
        "Max GPU Mem",
    ]
    print("\n" + " | ".join(headers))
    print(" | ".join("-" * len(header) for header in headers))
    for run in runs:
        gpu = run["gpu"]
        max_gpu = (
            f"{gpu['maximum_gpu_memory_used_mb']:.0f} MB" if gpu.get("available") else "unavailable"
        )
        print(
            " | ".join(
                [
                    str(run["concurrency"]),
                    str(run["successful_requests"]),
                    str(run["failed_requests"]),
                    f"{run['wall_clock_seconds']:.2f}s",
                    f"{run['pages_per_second']:.3f}",
                    f"{run['pages_per_minute']:.1f}",
                    f"{run['average_request_latency_seconds']:.2f}s",
                    f"{run['p95_latency_seconds']:.2f}s",
                    max_gpu,
                ]
            )
        )

    print(f"\nBest observed concurrency: {conclusion['best_observed_concurrency']}")
    print("Reason:")
    for reason in conclusion["reason"]:
        print(f"- {reason}")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        default=_env("LIGHTON_OCR_BENCHMARK_INPUT"),
        help="Directory containing representative PDFs/images/text/office files.",
    )
    parser.add_argument(
        "--concurrency",
        default=_env("LIGHTON_OCR_BENCHMARK_CONCURRENCY", DEFAULT_CONCURRENCY),
        help="Comma-separated concurrency levels, e.g. 1,2,4,8,12,16.",
    )
    parser.add_argument("--url", default=_env("LIGHTON_OCR_URL") or _env("LIGHTON_URL"))
    parser.add_argument("--model", default=_env("LIGHTON_OCR_MODEL") or _env("LIGHTON_MODEL"))
    parser.add_argument("--warmup", type=int, default=_int_env("LIGHTON_OCR_BENCHMARK_WARMUP", 5))
    parser.add_argument("--max-pages", type=int, default=None)
    parser.add_argument(
        "--output-dir",
        default=_env("LIGHTON_OCR_BENCHMARK_OUTPUT_DIR", str(ROOT.parent / "benchmark-results")),
    )
    parser.add_argument(
        "--gpu-sample-interval",
        type=float,
        default=_float_env("LIGHTON_OCR_BENCHMARK_GPU_INTERVAL", 3.0),
    )
    parser.add_argument("--no-gpu", action="store_true")
    parser.add_argument(
        "--prompt",
        default=_env("LIGHTON_OCR_BENCHMARK_PROMPT") or Settings().lighton_prompt,
    )
    return parser


async def async_main(args: argparse.Namespace) -> int:
    if not args.input:
        raise ValueError("--input or LIGHTON_OCR_BENCHMARK_INPUT is required")

    if args.url:
        os.environ["LIGHTON_OCR_URL"] = args.url
    if args.model:
        os.environ["LIGHTON_OCR_MODEL"] = args.model

    settings = Settings()
    concurrency_levels = parse_concurrency(args.concurrency)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="lightonocr-benchmark-pages-") as tmp:
        page_dir = Path(tmp)
        print(f"Rendering benchmark dataset from {args.input} ...")
        pages = await render_dataset(
            Path(args.input),
            settings=settings,
            output_dir=page_dir,
            max_pages=args.max_pages,
        )
        print(f"Prepared {len(pages)} page-level OCR requests.")
        if not pages:
            raise ValueError("dataset rendered zero pages")

        print(f"Running {args.warmup} warm-up request(s) ...")
        await run_warmup(
            pages,
            settings=settings,
            warmup_requests=args.warmup,
            prompt=args.prompt,
        )

        runs: list[dict[str, Any]] = []
        for concurrency in concurrency_levels:
            print(f"\nRunning concurrency={concurrency} over {len(pages)} pages ...")
            run = await run_concurrency_level(
                pages,
                settings=settings,
                concurrency=concurrency,
                prompt=args.prompt,
                collect_gpu=not args.no_gpu,
                gpu_interval_seconds=args.gpu_sample_interval,
            )
            runs.append(run)
            print(
                f"done: success={run['successful_requests']} failed={run['failed_requests']} "
                f"pages/sec={run['pages_per_second']:.3f} p95={run['p95_latency_seconds']:.2f}s"
            )

    conclusion = best_observed_concurrency(runs)
    payload = {
        "benchmark": "lightonocr-concurrency",
        "created_at": timestamp,
        "configuration": {
            "endpoint_url": _env("LIGHTON_OCR_URL") or settings.lighton_url,
            "model": _env("LIGHTON_OCR_MODEL") or settings.lighton_model,
            "input": str(Path(args.input).resolve()),
            "concurrency_levels": concurrency_levels,
            "warmup_requests": args.warmup,
            "total_pages": runs[0]["total_pages"] if runs else 0,
            "timeout_seconds": settings.lighton_timeout_seconds,
            "retries": settings.lighton_retries,
            "max_output_tokens": settings.lighton_max_output_tokens,
            "temperature": settings.lighton_temperature,
            "gpu_sampling_enabled": not args.no_gpu,
        },
        "runs": runs,
        "conclusion": conclusion,
    }
    result_path = output_dir / f"lightonocr-concurrency-{timestamp}.json"
    result_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print_summary(runs, conclusion)
    print(f"\nJSON results saved to {result_path}")
    return 0


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    try:
        return asyncio.run(async_main(args))
    except KeyboardInterrupt:
        print("benchmark interrupted", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"benchmark failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
