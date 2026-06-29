#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

CDAC_HOST="${CDAC_HOST:-apis.airawat.cdac.in}"
CDAC_PROXY="${CDAC_PROXY:-10.201.6.100:1080}"
CDAC_EMBEDDINGS_URL="${CDAC_EMBEDDINGS_URL:-https://${CDAC_HOST}/msebisec/v1/embeddings}"
CDAC_CA_CERT="${CDAC_CA_CERT:-${SCRIPT_DIR}/pem/cdac-ca.pem}"
EMBEDDING_MODEL="${EMBEDDING_MODEL_FOR_TEST:-intfloat/multilingual-e5-large-instruct}"
NEMOTRON_TEST_URL="${NEMOTRON_TEST_URL:-}"
NEMOTRON_MODEL="${NEMOTRON_MODEL:-${LITELLM_BEST_AGENTIC_MODEL:-}}"
NEMOTRON_API_KEY="${NEMOTRON_API_KEY:-}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[test]${NC} $*"; }
pass() { echo -e "${GREEN}[pass]${NC} $*"; }
warn() { echo -e "${YELLOW}[skip]${NC} $*"; }
fail() { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

require_container() {
  local name="$1"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)"
  [ "${running}" = "true" ] || fail "Container ${name} is not running"
}

get_cdac_key() {
  if [ -n "${CDAC_API_KEY:-}" ]; then
    printf "%s" "${CDAC_API_KEY}"
    return
  fi

  docker exec vespa sh -lc 'printf "%s" "$VESPA_SECRET_CDAC_API_KEY"'
}

test_vespa_to_proxy() {
  local cdac_key="$1"

  log "Vespa -> TEI batch proxy -> CDAC embeddings"
  docker exec -e CDAC_KEY="${cdac_key}" -e EMBEDDING_MODEL="${EMBEDDING_MODEL}" vespa sh -lc '
    set -e
    payload="$(printf "{\"input\":[\"query: hello world\"],\"model\":\"%s\",\"encoding_format\":\"float\"}" "$EMBEDDING_MODEL")"
    curl -fsS -o /tmp/vespa-proxy-embedding.json -w "HTTP %{http_code}\n" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CDAC_KEY}" \
      -d "${payload}" \
      http://tei-batch-proxy:8080/v1/embeddings
  '
  pass "Vespa can reach CDAC through tei-batch-proxy"
}

test_vespa_to_cdac_direct() {
  local cdac_key="$1"

  log "Vespa -> CDAC embeddings directly through ${CDAC_PROXY}"
  [ -f "${CDAC_CA_CERT}" ] || fail "Missing ${CDAC_CA_CERT}"
  docker cp "${CDAC_CA_CERT}" vespa:/tmp/cdac-airawat.pem >/dev/null
  docker exec -e CDAC_KEY="${cdac_key}" -e CDAC_PROXY="${CDAC_PROXY}" -e CDAC_EMBEDDINGS_URL="${CDAC_EMBEDDINGS_URL}" -e EMBEDDING_MODEL="${EMBEDDING_MODEL}" vespa sh -lc '
    set -e
    payload="$(printf "{\"input\":[\"query: hello world\"],\"model\":\"%s\",\"encoding_format\":\"float\"}" "$EMBEDDING_MODEL")"
    curl -fsS --proxy "http://${CDAC_PROXY}" --cacert /tmp/cdac-airawat.pem \
      -o /tmp/vespa-cdac-direct-embedding.json -w "HTTP %{http_code}\n" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CDAC_KEY}" \
      -d "${payload}" \
      "${CDAC_EMBEDDINGS_URL}"
  '
  pass "Vespa can reach CDAC directly with the captured CA"
}

test_proxy_to_cdac_direct() {
  local cdac_key="$1"

  log "TEI batch proxy container -> CDAC embeddings directly through ${CDAC_PROXY}"
  docker exec -i \
    -e CDAC_KEY="${cdac_key}" \
    -e CDAC_HOST="${CDAC_HOST}" \
    -e CDAC_PROXY="${CDAC_PROXY}" \
    -e EMBEDDING_MODEL="${EMBEDDING_MODEL}" \
    sebi-tei-batch-proxy node - <<'NODE'
const http = require("node:http");
const https = require("node:https");
const tls = require("node:tls");
const fs = require("node:fs");

const host = process.env.CDAC_HOST;
const [proxyHost, proxyPortRaw] = process.env.CDAC_PROXY.split(":");
const proxyPort = Number(proxyPortRaw || 1080);
const body = JSON.stringify({
  input: ["query: hello world"],
  model: process.env.EMBEDDING_MODEL,
  encoding_format: "float",
});
const ca = fs.readFileSync("/certs/cdac-ca.pem", "utf8");

function done(error) {
  if (error) {
    console.error(error.stack || error.message || error);
    process.exit(1);
  }
}

const connect = http.request({
  host: proxyHost,
  port: proxyPort,
  method: "CONNECT",
  path: `${host}:443`,
  headers: { Host: `${host}:443` },
});

connect.on("connect", (res, socket) => {
  if (res.statusCode !== 200) {
    socket.destroy();
    done(new Error(`CONNECT failed with HTTP ${res.statusCode}`));
    return;
  }

  const stream = tls.connect({ socket, servername: host, ca }, () => {
    const req = https.request({
      hostname: host,
      port: 443,
      method: "POST",
      path: "/msebisec/v1/embeddings",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${process.env.CDAC_KEY}`,
        "Content-Length": Buffer.byteLength(body),
      },
      createConnection: () => stream,
    }, (upstreamRes) => {
      let responseBody = "";
      upstreamRes.setEncoding("utf8");
      upstreamRes.on("data", (chunk) => { responseBody += chunk; });
      upstreamRes.on("end", () => {
        console.log(`HTTP ${upstreamRes.statusCode}`);
        if (upstreamRes.statusCode !== 200) {
          console.error(responseBody.slice(0, 1000));
          process.exit(1);
        }
        const parsed = JSON.parse(responseBody);
        console.log(`items=${parsed.data?.length || 0} dim=${parsed.data?.[0]?.embedding?.length || 0} model=${parsed.model || ""}`);
      });
    });

    req.on("error", done);
    req.end(body);
  });

  stream.on("error", done);
});

connect.on("error", done);
connect.end();
NODE
  pass "TEI batch proxy container can reach CDAC directly"
}

test_proxy_local_endpoint() {
  local cdac_key="$1"

  log "TEI batch proxy local /v1/embeddings endpoint"
  docker exec -i -e CDAC_KEY="${cdac_key}" -e EMBEDDING_MODEL="${EMBEDDING_MODEL}" sebi-tei-batch-proxy node - <<'NODE'
const body = {
  input: ["query: hello world"],
  model: process.env.EMBEDDING_MODEL,
  encoding_format: "float",
};

fetch("http://localhost:8080/v1/embeddings", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${process.env.CDAC_KEY}`,
  },
  body: JSON.stringify(body),
}).then(async (res) => {
  const json = await res.json();
  console.log(`HTTP ${res.status}`);
  if (!res.ok) {
    console.error(JSON.stringify(json).slice(0, 1000));
    process.exit(1);
  }
  console.log(`items=${json.data?.length || 0} dim=${json.data?.[0]?.embedding?.length || 0} model=${json.model || ""}`);
}).catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
NODE
  pass "TEI batch proxy local endpoint works"
}

test_nemotron_container() {
  local container="$1"

  if [ -z "${NEMOTRON_TEST_URL}" ] || [ -z "${NEMOTRON_MODEL}" ]; then
    warn "Skipping ${container} -> Nemotron test. Set NEMOTRON_TEST_URL and NEMOTRON_MODEL to enable it."
    return
  fi

  log "${container} -> Nemotron chat/completions endpoint"
  docker exec \
    -e NEMOTRON_TEST_URL="${NEMOTRON_TEST_URL}" \
    -e NEMOTRON_MODEL="${NEMOTRON_MODEL}" \
    -e NEMOTRON_API_KEY="${NEMOTRON_API_KEY}" \
    "${container}" sh -lc '
      set -e
      payload="$(printf "{\"model\":\"%s\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with ok\"}],\"max_tokens\":1}" "$NEMOTRON_MODEL")"
      if [ -n "${NEMOTRON_API_KEY:-}" ]; then
        curl -fsS -o /tmp/nemotron-reachability.json -w "HTTP %{http_code}\n" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${NEMOTRON_API_KEY}" \
          -d "${payload}" \
          "${NEMOTRON_TEST_URL}"
      else
        curl -fsS -o /tmp/nemotron-reachability.json -w "HTTP %{http_code}\n" \
          -H "Content-Type: application/json" \
          -d "${payload}" \
          "${NEMOTRON_TEST_URL}"
      fi
    '
  pass "${container} can reach Nemotron endpoint"
}

require_container vespa
require_container sebi-tei-batch-proxy

CDAC_KEY="$(get_cdac_key)"
[ -n "${CDAC_KEY}" ] || fail "CDAC_API_KEY is empty and VESPA_SECRET_CDAC_API_KEY could not be read from vespa"

test_vespa_to_proxy "${CDAC_KEY}"
test_vespa_to_cdac_direct "${CDAC_KEY}"
test_proxy_to_cdac_direct "${CDAC_KEY}"
test_proxy_local_endpoint "${CDAC_KEY}"

if [ "$(docker inspect -f '{{.State.Running}}' xyne-app 2>/dev/null || true)" = "true" ]; then
  test_nemotron_container xyne-app
fi

if [ "$(docker inspect -f '{{.State.Running}}' xyne-app-sync 2>/dev/null || true)" = "true" ]; then
  test_nemotron_container xyne-app-sync
fi

pass "Reachability checks completed"
