"""Redis storage and stream publication for async OCR results."""

from __future__ import annotations

import inspect
import json
from typing import Any

from config import settings


class RedisResultPublisher:
    def __init__(
        self,
        *,
        redis_url: str = settings.redis_url,
        results_stream: str = settings.results_stream,
        result_key_prefix: str = settings.result_key_prefix,
        result_ttl_seconds: int = settings.result_ttl_seconds,
        client: Any | None = None,
    ) -> None:
        self.redis_url = redis_url
        self.results_stream = results_stream
        self.result_key_prefix = result_key_prefix.rstrip(":")
        self.result_ttl_seconds = result_ttl_seconds
        self._client = client

    def result_key(self, job_id: str) -> str:
        return f"{self.result_key_prefix}:{job_id}"

    async def store_result(self, job_id: str, result: dict[str, Any]) -> str:
        key = self.result_key(job_id)
        payload = json.dumps(result, default=str, separators=(",", ":"))
        await _maybe_await(self._redis.setex(key, self.result_ttl_seconds, payload))
        return key

    async def publish_success(
        self,
        *,
        job_id: str,
        file_id: str,
        doc_id: str,
        result_key: str,
        vespa_doc_id: str | None = None,
    ) -> Any:
        fields = _base_fields(job_id, file_id, doc_id, vespa_doc_id)
        fields.update({"status": "ok", "result_key": result_key})
        return await _maybe_await(self._redis.xadd(self.results_stream, fields, id="*"))

    async def publish_failure(
        self,
        *,
        job_id: str,
        file_id: str,
        doc_id: str,
        error: str,
        vespa_doc_id: str | None = None,
    ) -> Any:
        fields = _base_fields(job_id, file_id, doc_id, vespa_doc_id)
        fields.update({"status": "failed", "error": compact_error(error)})
        return await _maybe_await(self._redis.xadd(self.results_stream, fields, id="*"))

    @property
    def _redis(self) -> Any:
        if self._client is None:
            try:
                from redis.asyncio import Redis
            except ImportError as exc:
                raise RuntimeError("redis package is not installed; install redis>=5.0.0") from exc
            self._client = Redis.from_url(self.redis_url, decode_responses=True)
        return self._client


def compact_error(error: Any, max_length: int = 512) -> str:
    text = str(error or "unknown error").replace("\n", " ").strip()
    if not text:
        text = "unknown error"
    if len(text) <= max_length:
        return text
    return text[: max_length - 3] + "..."


def _base_fields(
    job_id: str,
    file_id: str,
    doc_id: str,
    vespa_doc_id: str | None = None,
) -> dict[str, str]:
    fields = {"job_id": job_id, "file_id": file_id, "doc_id": doc_id}
    if vespa_doc_id:
        fields["vespa_doc_id"] = vespa_doc_id
    return fields


async def _maybe_await(value: Any) -> Any:
    if inspect.isawaitable(value):
        return await value
    return value


publisher = RedisResultPublisher()
