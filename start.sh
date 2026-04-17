#!/usr/bin/env bash
set -euo pipefail

# Xyne air-gapped RHEL/Docker startup.
# This script assumes Docker is already installed and all required images are
# available as tar files under ../images. It never pulls or builds images.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SCRIPT_DIR}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[start]${NC} $*"; }
info() { echo -e "${BLUE}[info]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.infrastructure-cpu.yml -f docker-compose.app.yml -f docker-compose.sync.yml)
INFRA_FILES=(-f docker-compose.yml -f docker-compose.infrastructure-cpu.yml)

REQUIRED_IMAGES=(
  "busybox:latest"
  "grafana/grafana:latest"
  "grafana/loki:3.4.1"
  "grafana/promtail:3.4.1"
  "livekit/livekit-server:v1.9.1"
  "nginx:1.26-alpine"
  "postgres:15-alpine"
  "prom/prometheus:latest"
  "quay.io/keycloak/keycloak:26.0"
  "vespa-deploy:latest"
  "vespaengine/vespa:latest"
  "xynehq/xyne:latest"
)

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

get_docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    die "Docker Compose is not available"
  fi
}

check_bundle_layout() {
  [ -d "${BUNDLE_DIR}/images" ] || die "Expected Docker image tarballs under ${BUNDLE_DIR}/images"
  [ -d "${BUNDLE_DIR}/grafana/provisioning" ] || die "Expected Grafana provisioning files under ${BUNDLE_DIR}/grafana/provisioning"
}

detect_public_url() {
  if [ -n "${XYNE_PUBLIC_URL:-}" ]; then
    printf "%s" "${XYNE_PUBLIC_URL%/}"
    return
  fi

  local existing_host=""
  if [ -f .env ]; then
    existing_host="$(grep -E '^HOST=' .env | tail -n 1 | cut -d= -f2- | tr -d '"' || true)"
  fi

  case "${existing_host}" in
    http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*|"")
      ;;
    *)
      printf "%s" "${existing_host%/}"
      return
      ;;
  esac

  local host_ip=""
  if command -v hostname >/dev/null 2>&1; then
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "${host_ip}" ]; then
      host_ip="$(hostname -i 2>/dev/null | awk '{print $1}' || true)"
    fi
  fi
  host_ip="${host_ip:-localhost}"
  printf "http://%s:3000" "${host_ip}"
}

url_host() {
  printf "%s" "$1" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:.*$##'
}

env_value_is_empty() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" .env 2>/dev/null | tail -n 1 || true)"
  if [ -z "${line}" ]; then
    return 0
  fi
  local value="${line#*=}"
  value="${value%$'\r'}"
  [ -z "${value}" ] || [ "${value}" = '""' ] || [ "${value}" = "''" ]
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"
  touch .env
  if grep -q -E "^${key}=" .env 2>/dev/null; then
    awk -v key="${key}" -v value="${value}" '
      BEGIN { updated = 0 }
      $0 ~ "^" key "=" && updated == 0 {
        print key "=" value
        updated = 1
        next
      }
      $0 ~ "^" key "=" { next }
      { print }
    ' .env > .env.tmp
    mv .env.tmp .env
  else
    printf "%s=%s\n" "${key}" "${value}" >> .env
  fi
}

set_env_if_missing() {
  local key="$1"
  local value="$2"
  if env_value_is_empty "${key}"; then
    set_env_value "${key}" "${value}"
  fi
}

load_env_file() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
}

configure_env() {
  log "Configuring .env..."

  if [ ! -f .env ]; then
    touch .env
  fi
  load_env_file

  local public_url
  public_url="$(detect_public_url)"
  local public_host
  public_host="$(url_host "${public_url}")"
  local no_proxy_list
  no_proxy_list="localhost,127.0.0.1,xyne-db,vespa,keycloak,xyne-keycloak,xyne-app,app,xyne-app-sync,app-sync,xyne-nginx,nginx,livekit,loki,xyne-prometheus,xyne-grafana,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.local"

  set_env_value "NODE_ENV" "production"
  set_env_value "DATABASE_HOST" "xyne-db"
  set_env_value "DATABASE_PORT" "5432"
  set_env_value "DATABASE_USER" "xyne"
  set_env_value "DATABASE_PASSWORD" "xyne"
  set_env_value "DATABASE_URL" "postgresql://xyne:xyne@xyne-db:5432/xyne?sslmode=disable"
  set_env_value "POSTGRES_PASSWORD" "xyne"
  set_env_value "VESPA_HOST" "vespa"
  set_env_value "VESPA_FEED_PORT" "8080"
  set_env_value "VESPA_QUERY_PORT" "8081"
  set_env_value "VESPA_REQUIRED" "false"
  set_env_value "DOCKER_UID" "${DOCKER_UID:-1000}"
  set_env_value "DOCKER_GID" "${DOCKER_GID:-1000}"
  set_env_value "XYNE_DATA_DIR" "${XYNE_DATA_DIR:-../data}"
  set_env_value "HOST" "${public_url}"
  set_env_value "NGINX_DOMAIN" "${public_host}"
  set_env_value "PORT" "3000"
  set_env_value "APP_PORT" "3000"
  set_env_value "METRICS_PORT" "${METRICS_PORT:-3001}"
  set_env_value "REASONING" "true"
  set_env_value "EMBEDDING_MODEL" "bge-small-en-v1.5"

  set_env_value "KEYCLOAK_WEB_ENABLED" "true"
  set_env_value "KEYCLOAK_IMAGE" "quay.io/keycloak/keycloak:26.0"
  set_env_value "KEYCLOAK_PORT" "${KEYCLOAK_PORT:-8082}"
  set_env_value "KEYCLOAK_PUBLIC_BASE_URL" "${public_url}/keycloak"
  set_env_value "KEYCLOAK_INTERNAL_BASE_URL" "http://keycloak:8080/keycloak"
  set_env_value "KEYCLOAK_REALM" "xyne-shared"
  set_env_value "KEYCLOAK_CLIENT_ID" "xyne-web"
  set_env_value "KEYCLOAK_WORKSPACE_EXTERNAL_ID" "xyne-shared-workspace"
  set_env_value "KEYCLOAK_LOGOUT_REDIRECT_URL" "/auth"
  set_env_value "KC_DB_USERNAME" "xyne"
  set_env_value "KC_DB_PASSWORD" "xyne"
  set_env_value "KEYCLOAK_ADMIN" "${KEYCLOAK_ADMIN:-admin}"
  set_env_value "KEYCLOAK_BOOTSTRAP_RESET_ADMIN_PASSWORD" "false"
  set_env_value "XYNE_BOOTSTRAP_ADMIN_EMAIL" "${XYNE_BOOTSTRAP_ADMIN_EMAIL:-admin@xyne.local}"
  set_env_value "XYNE_BOOTSTRAP_ADMIN_NAME" "\"${XYNE_BOOTSTRAP_ADMIN_NAME:-Xyne Admin}\""
  set_env_value "XYNE_BOOTSTRAP_WORKSPACE_NAME" "\"${XYNE_BOOTSTRAP_WORKSPACE_NAME:-Xyne Shared}\""
  set_env_value "XYNE_BOOTSTRAP_WORKSPACE_DOMAIN" "${XYNE_BOOTSTRAP_WORKSPACE_DOMAIN:-xyne.local}"

  set_env_if_missing "ENCRYPTION_KEY" "$(generate_secret)"
  set_env_if_missing "JWT_SECRET" "$(generate_secret)"
  set_env_if_missing "ACCESS_TOKEN_SECRET" "$(generate_secret)"
  set_env_if_missing "REFRESH_TOKEN_SECRET" "$(generate_secret)"
  set_env_if_missing "SERVICE_ACCOUNT_ENCRYPTION_KEY" "$(generate_secret)"
  set_env_if_missing "USER_SECRET" "$(generate_secret)"
  set_env_if_missing "KEYCLOAK_CLIENT_SECRET" "$(generate_secret)"
  set_env_if_missing "KEYCLOAK_ADMIN_PASSWORD" "$(generate_secret)"
  set_env_if_missing "XYNE_BOOTSTRAP_ADMIN_PASSWORD" "$(generate_secret)"

  set_env_value "GOOGLE_WEB_LOGIN_ENABLED" "${GOOGLE_WEB_LOGIN_ENABLED:-false}"
  set_env_value "GOOGLE_REDIRECT_URI" "${public_url}/v1/auth/callback"
  set_env_value "GOOGLE_PROD_REDIRECT_URI" "${public_url}/v1/auth/callback"

  set_env_value "LIVEKIT_API_KEY" "${LIVEKIT_API_KEY:-devkey}"
  set_env_value "LIVEKIT_API_SECRET" "${LIVEKIT_API_SECRET:-devsecret}"
  set_env_value "LIVEKIT_URL" "ws://${public_host}:3000/rtc"
  set_env_value "LIVEKIT_CLIENT_URL" "${public_url}"
  set_env_value "SYNC_SERVER_HOST" "app-sync"
  set_env_value "MAIN_SERVER_HOST" "app"

  set_env_value "NO_PROXY" "${NO_PROXY:-${no_proxy:-${no_proxy_list}}}"
  set_env_value "no_proxy" "${no_proxy:-${NO_PROXY:-${no_proxy_list}}}"

  if [ -n "${HTTP_PROXY:-}" ]; then set_env_value "HTTP_PROXY" "${HTTP_PROXY}"; fi
  if [ -n "${HTTPS_PROXY:-}" ]; then set_env_value "HTTPS_PROXY" "${HTTPS_PROXY}"; fi
  if [ -n "${http_proxy:-}" ]; then set_env_value "http_proxy" "${http_proxy}"; fi
  if [ -n "${https_proxy:-}" ]; then set_env_value "https_proxy" "${https_proxy}"; fi

  if command -v getent >/dev/null 2>&1; then
    set_env_value "DOCKER_GROUP_ID" "$(getent group docker | cut -d: -f3 2>/dev/null || echo 999)"
  else
    set_env_value "DOCKER_GROUP_ID" "$(grep '^docker:' /etc/group 2>/dev/null | cut -d: -f3 || echo 999)"
  fi

  log ".env ready for ${public_url}"
}

load_images() {
  log "Loading local Docker image tarballs..."
  local image_dir="${BUNDLE_DIR}/images"
  shopt -s nullglob
  local tarfiles=("${image_dir}"/*.tar)
  shopt -u nullglob

  if [ "${#tarfiles[@]}" -eq 0 ]; then
    die "No image tar files found under ${image_dir}"
  fi

  if [ "${XYNE_SKIP_IMAGE_LOAD:-false}" = "true" ]; then
    warn "Skipping docker load because XYNE_SKIP_IMAGE_LOAD=true"
  else
    local tarfile
    for tarfile in "${tarfiles[@]}"; do
      info "Loading $(basename "${tarfile}")"
      docker load -i "${tarfile}" >/dev/null
    done
  fi

  local missing=()
  local image
  for image in "${REQUIRED_IMAGES[@]}"; do
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      missing+=("${image}")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf "%s\n" "${missing[@]}" >&2
    die "Required Docker images are missing after loading tarballs"
  fi

  log "All required images are available locally"
}

setup_dirs() {
  load_env_file
  local data_dir="${XYNE_DATA_DIR:-./data}"
  local data_dir_abs

  log "Creating data directories under ${data_dir}..."
  mkdir -p "${data_dir}"/{postgres-data,vespa-data,app-uploads,app-logs,app-assets,app-migrations,app-downloads,grafana-storage,loki-data,promtail-data,prometheus-data,vespa-models}
  mkdir -p "${data_dir}/vespa-data/tmp"
  data_dir_abs="$(cd "${data_dir}" && pwd -P)"

  chmod -f 755 "${data_dir_abs}" 2>/dev/null || true
  chmod -f 755 "${data_dir_abs}"/* 2>/dev/null || true

  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || true)" = "Enforcing" ] && command -v chcon >/dev/null 2>&1; then
    warn "SELinux is enforcing; applying container file labels to ${data_dir_abs}"
    chcon -Rt svirt_sandbox_file_t "${data_dir_abs}" 2>/dev/null || warn "Could not apply SELinux labels; bind mounts may need manual labeling"
  fi

  docker network create xyne >/dev/null 2>&1 || true
}

setup_permissions() {
  load_env_file
  local data_dir="${XYNE_DATA_DIR:-./data}"
  local data_dir_abs
  local uid="${DOCKER_UID:-1000}"
  local gid="${DOCKER_GID:-1000}"
  data_dir_abs="$(cd "${data_dir}" && pwd -P)"

  log "Setting directory ownership with busybox..."
  local dir
  for dir in postgres-data vespa-data vespa-models app-uploads app-logs app-assets app-migrations app-downloads grafana-storage; do
    docker run --rm -v "${data_dir_abs}/${dir}:/data" busybox:latest chown -R "${uid}:${gid}" /data 2>/dev/null || true
  done

  docker run --rm -v "${data_dir_abs}/prometheus-data:/data" busybox:latest sh -c 'mkdir -p /data && chown -R 65534:65534 /data' 2>/dev/null || true
  docker run --rm -v "${data_dir_abs}/loki-data:/data" busybox:latest sh -c 'mkdir -p /data && chown -R 10001:10001 /data' 2>/dev/null || true
  docker run --rm -v "${data_dir_abs}/promtail-data:/data" busybox:latest sh -c 'mkdir -p /data && chown -R 10001:10001 /data' 2>/dev/null || true
}

ensure_migrations() {
  local dc="$1"
  load_env_file
  local data_dir="${XYNE_DATA_DIR:-./data}"
  local data_dir_abs

  mkdir -p "${data_dir}"
  data_dir_abs="$(cd "${data_dir}" && pwd -P)"
  mkdir -p "${data_dir_abs}/app-migrations"

  if [ -f "${data_dir_abs}/app-migrations/meta/_journal.json" ]; then
    info "Database migrations already exist in ${data_dir}/app-migrations"
    return
  fi

  log "Generating database migrations from the Xyne image..."
  ${dc} "${COMPOSE_FILES[@]}" --profile keycloak run --rm --no-deps --pull never app bun run generate
  [ -f "${data_dir_abs}/app-migrations/meta/_journal.json" ] || die "Could not prepare Drizzle migrations"
}

process_prometheus_config() {
  if [ -f prometheus-selfhosted.yml.template ]; then
    load_env_file
    local metrics_port="${METRICS_PORT:-3001}"
    sed "s|[$]METRICS_PORT|${metrics_port}|g" prometheus-selfhosted.yml.template > prometheus-selfhosted.yml
  fi
}

wait_for_postgres() {
  log "Waiting for PostgreSQL..."
  local attempts=0
  until docker exec xyne-db pg_isready -U xyne -d xyne >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 60 ]; then
      die "PostgreSQL did not become ready"
    fi
    sleep 2
  done
}

ensure_keycloak_database() {
  log "Ensuring Keycloak database exists..."
  if docker exec -e PGPASSWORD=xyne xyne-db psql -U xyne -tAc "SELECT 1 FROM pg_database WHERE datname = 'keycloak'" | grep -q "1"; then
    info "Keycloak database already exists"
    return
  fi
  docker exec -e PGPASSWORD=xyne xyne-db psql -U xyne -c "CREATE DATABASE keycloak;"
}

wait_for_keycloak() {
  load_env_file

  local endpoint="http://localhost:${KEYCLOAK_PORT:-8082}/keycloak/realms/master"
  log "Waiting for Keycloak at ${endpoint}..."

  local attempts=0
  until http_get_ok "${endpoint}"; do
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 90 ]; then
      die "Keycloak did not become ready"
    fi
    sleep 2
  done
}

http_get_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "${url}" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null "${url}" >/dev/null 2>&1
  else
    docker run --rm --network host busybox:latest wget -q -O /dev/null "${url}" >/dev/null 2>&1
  fi
}

open_firewall_port() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Opening port 3000 in firewalld..."
    firewall-cmd --permanent --add-port=3000/tcp >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
}

cleanup_conflicting_containers() {
  log "Removing old Xyne containers with fixed names..."
  local name
  for name in \
    xyne-db \
    xyne-app \
    xyne-app-sync \
    xyne-keycloak \
    xyne-nginx \
    xyne-prometheus \
    xyne-grafana \
    vespa \
    vespa-deploy \
    livekit \
    loki \
    promtail; do
    docker rm -f "${name}" >/dev/null 2>&1 || true
  done
}

start_services() {
  local dc="$1"

  log "Starting PostgreSQL..."
  ${dc} "${INFRA_FILES[@]}" up -d --pull never xyne-db
  wait_for_postgres
  ensure_keycloak_database

  log "Starting infrastructure with Keycloak..."
  ${dc} "${INFRA_FILES[@]}" --profile keycloak up -d --pull never
  wait_for_keycloak

  log "Running app migrations..."
  ${dc} "${COMPOSE_FILES[@]}" --profile keycloak run --rm --no-deps --pull never app bun run migrate

  log "Bootstrapping Keycloak realm and admin user..."
  ${dc} "${COMPOSE_FILES[@]}" --profile keycloak run --rm --no-deps --pull never app bun run keycloak:bootstrap

  log "Starting application services..."
  ${dc} "${COMPOSE_FILES[@]}" --profile keycloak up -d --pull never
}

print_summary() {
  load_env_file
  echo ""
  log "Xyne air-gapped deployment started"
  echo ""
  echo "  App:      ${HOST:-http://localhost:3000}"
  echo "  Keycloak: ${KEYCLOAK_PUBLIC_BASE_URL:-http://localhost:3000/keycloak}"
  echo "  Grafana:  ${HOST:-http://localhost:3000}/grafana"
  echo ""
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main() {
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}  Xyne Air-Gapped Deployment${NC}"
  echo -e "${BLUE}============================================${NC}"

  require_command docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not running"
  check_bundle_layout
  local dc
  dc="$(get_docker_compose_cmd)"

  load_images
  configure_env
  setup_dirs
  setup_permissions
  process_prometheus_config
  open_firewall_port
  cleanup_conflicting_containers
  ensure_migrations "${dc}"
  start_services "${dc}"
  print_summary
}

main "$@"
