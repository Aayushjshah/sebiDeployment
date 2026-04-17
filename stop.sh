#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

${DC} \
  -f docker-compose.yml \
  -f docker-compose.infrastructure-cpu.yml \
  -f docker-compose.app.yml \
  -f docker-compose.sync.yml \
  --profile keycloak \
  down

echo "All services stopped."
