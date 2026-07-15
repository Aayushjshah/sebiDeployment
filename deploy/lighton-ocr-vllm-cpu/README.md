# LightOnOCR vLLM CPU Air-Gapped Image

This deployment artifact builds a Linux x86_64 CPU container for
`lightonai/LightOnOCR-2-1B-bbox` served through vLLM's OpenAI-compatible API.

The SEBI VM is a RHEL Docker host, but the container itself uses vLLM's
published Linux x86_64 CPU image. That is compatible with the existing Docker
deployment pattern in this repo: build or pull on an internet-connected machine,
save as a tarball, copy into the air-gapped bundle, then `docker load` on the VM.

## Build On An Internet-Connected Machine

From the repo root:

```bash
./scripts/build-lighton-ocr-vllm-cpu-image.sh
```

Optional overrides:

```bash
MODEL_ID=lightonai/LightOnOCR-2-1B-bbox \
IMAGE_TAG=lighton-ocr-vllm-cpu:sebi-20260714 \
OUT_DIR=/path/to/bundle/images \
./scripts/build-lighton-ocr-vllm-cpu-image.sh
```

The script writes:

```text
../images/lighton-ocr-vllm-cpu-sebi-20260714.tar
```

## Load On The SEBI VM

```bash
cd /root/Documents/sebiDeployment
docker load -i ../images/lighton-ocr-vllm-cpu-sebi-20260714.tar
```

## Run Beside The Existing Stack

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.lighton-ocr-vllm-cpu.yml \
  up -d lighton-ocr-vllm-cpu
```

The service listens on:

```text
http://localhost:8003/v1/chat/completions
```

Inside the Docker network, other services can call:

```text
http://lighton-ocr-vllm-cpu:8000/v1/chat/completions
```

## Validate

```bash
curl --noproxy '*' -fsS http://localhost:8003/health && echo
```

Then render and OCR one page:

```bash
pip install pypdfium2
./scripts/test-lighton-ocr-vllm-cpu.sh /path/to/test.pdf 0
```

Watch resource use:

```bash
docker stats lighton-ocr-vllm-cpu
docker logs -f --tail 200 lighton-ocr-vllm-cpu
```

## Wire Existing OCR Wrapper To Local vLLM

After latency and quality are acceptable, point the existing wrapper at the
local vLLM endpoint:

```text
LIGHTON_URL=http://lighton-ocr-vllm-cpu:8000/v1/chat/completions
LIGHTON_MODEL=lightonai/LightOnOCR-2-1B-bbox
```

Do this as a separate compose/env change after testing. Keep the current remote
wrapper path available until local CPU performance is proven.

## CPU Notes

- Start with one request at a time: `MAX_NUM_SEQS=1`.
- Increase `LIGHTON_OCR_VLLM_CPU_KVCACHE_SPACE` only if the container has memory
  headroom.
- For large hosts, leave `VLLM_CPU_OMP_THREADS_BIND=auto` initially.
- If the host CPU has weak BF16/AVX512 support and vLLM fails, try:

```bash
LIGHTON_OCR_VLLM_DTYPE=float32 docker compose \
  -f docker-compose.yml \
  -f docker-compose.lighton-ocr-vllm-cpu.yml \
  up -d --force-recreate lighton-ocr-vllm-cpu
```
