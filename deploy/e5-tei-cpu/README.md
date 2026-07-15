# multilingual E5 TEI CPU Air-Gapped Image

This artifact builds a Linux x86_64 CPU container for
`intfloat/multilingual-e5-large-instruct` served by Hugging Face Text Embeddings
Inference through an OpenAI-compatible `/v1/embeddings` endpoint.

## Build On An Internet-Connected Machine

From the repo root:

```bash
./scripts/build-e5-tei-cpu-image.sh
```

Optional overrides:

```bash
IMAGE_TAG=e5-tei-cpu:sebi-20260714 \
OUT_DIR=/path/to/bundle/images \
./scripts/build-e5-tei-cpu-image.sh
```

The script writes:

```text
../images/e5-tei-cpu-sebi-20260714.tar
```

## Load On The SEBI VM

```bash
cd /root/Documents/sebiDeployment
docker load -i ../images/e5-tei-cpu-sebi-20260714.tar
```

## Run Beside The Existing Stack

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.e5-tei-cpu.yml \
  up -d e5-tei-cpu
```

The local TEI endpoint is:

```text
http://localhost:8093/v1/embeddings
```

## Validate

```bash
./scripts/embed-e5-cpu-file.sh deploy/e5-tei-cpu/sample-input.txt /tmp/e5-cpu-embedding.json
```

Expected output:

```text
items=1 dim=1024 model=intfloat/multilingual-e5-large-instruct output=/tmp/e5-cpu-embedding.json
```

The raw OpenAI-compatible embedding response is written to the output file.

To test the existing CDAC/GPU hosted E5 endpoint with the same input:

```bash
CDAC_API_KEY=... ./scripts/embed-e5-cdac-file.sh deploy/e5-tei-cpu/sample-input.txt /tmp/e5-cdac-embedding.json
```

## CPU Tuning

Start with the conservative defaults in `docker-compose.e5-tei-cpu.yml`:

```text
TEI_MAX_BATCH_TOKENS=8192
TEI_MAX_CLIENT_BATCH_SIZE=64
TEI_MAX_BATCH_REQUESTS=4
```

Increase batch size only after checking `docker stats e5-tei-cpu` under real
load.
