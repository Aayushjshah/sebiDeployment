#!/usr/bin/env bash
set -euo pipefail

# Starts the existing SEBI Compose deployment with the LDAP-enabled Xyne image.
# Existing .env values are preserved except for the deployment routes and the
# Keycloak LDAP claim contract required by this image.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

SOURCE_IMAGE="${XYNE_LDAP_IMAGE:-xyne-search:keycloak-ldap-mail-login-20260804}"
KEYCLOAK_BASE_IMAGE="${KEYCLOAK_BASE_IMAGE:-quay.io/keycloak/keycloak:26.0}"
KEYCLOAK_LDAP_IMAGE="${KEYCLOAK_LDAP_IMAGE:-sebi-keycloak:26.0-ldap-ca}"
KEYCLOAK_LDAP_DOCKERFILE="Dockerfile.keycloak-sebi-ldap-ca"
KEYCLOAK_LDAP_CA_BUNDLE="certs/sebi-ldap-ca-bundle.pem"
PUBLIC_URL="${XYNE_PUBLIC_URL:-http://10.102.44.2:3000}"
PUBLIC_HOST="${PUBLIC_URL#*://}"
PUBLIC_HOST="${PUBLIC_HOST%%[:/]*}"

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

set_env_value() {
  local key="$1"
  local value="$2"

  touch .env
  if grep -q -E "^${key}=" .env; then
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
    printf '%s=%s\n' "${key}" "${value}" >> .env
  fi
}

command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"
[ -f start.sh ] || die "Run this script from the sebiDeployment repository"
[ -f .env ] || die "Expected the existing deployment environment at ${SCRIPT_DIR}/.env"
[ -f "${KEYCLOAK_LDAP_DOCKERFILE}" ] || die "Expected ${KEYCLOAK_LDAP_DOCKERFILE} under ${SCRIPT_DIR}"
[ -s "${KEYCLOAK_LDAP_CA_BUNDLE}" ] || die "Expected a non-empty LDAP CA bundle at ${SCRIPT_DIR}/${KEYCLOAK_LDAP_CA_BUNDLE}"
docker image inspect "${SOURCE_IMAGE}" >/dev/null 2>&1 || die "Docker image ${SOURCE_IMAGE} is not loaded"
docker image inspect "${KEYCLOAK_BASE_IMAGE}" >/dev/null 2>&1 || die "Docker image ${KEYCLOAK_BASE_IMAGE} is not loaded"

certificate_starts="$(grep -c -- '-----BEGIN CERTIFICATE-----' "${KEYCLOAK_LDAP_CA_BUNDLE}" || true)"
certificate_ends="$(grep -c -- '-----END CERTIFICATE-----' "${KEYCLOAK_LDAP_CA_BUNDLE}" || true)"
if [ "${certificate_starts}" -lt 1 ] || [ "${certificate_starts}" -ne "${certificate_ends}" ]; then
  die "LDAP CA bundle must contain matching BEGIN/END CERTIFICATE blocks"
fi

printf '[ldap-start] Building Keycloak trust image with %s LDAP certificate(s)\n' "${certificate_starts}"
docker build --pull=false --network=none \
  --build-arg "KEYCLOAK_BASE_IMAGE=${KEYCLOAK_BASE_IMAGE}" \
  -f "${KEYCLOAK_LDAP_DOCKERFILE}" \
  -t "${KEYCLOAK_LDAP_IMAGE}" \
  .

printf '[ldap-start] Updating LDAP/Keycloak deployment variables in %s/.env\n' "${SCRIPT_DIR}"
set_env_value "XYNE_PUBLIC_URL" "${PUBLIC_URL}"
set_env_value "BACKENDV2_BASE_URL" "${PUBLIC_URL}"
set_env_value "BACKENDV2_UI_BASE_URL" "${PUBLIC_URL}"
set_env_value "KEYCLOAK_WORKSPACE_CLAIM" "xyne_workspace_external_id"
set_env_value "KEYCLOAK_LDAP_UPN_CLAIM" "ldap_upn"
set_env_value "KEYCLOAK_LDAP_OBJECT_GUID_CLAIM" "ldap_object_guid"
set_env_value "KEYCLOAK_LDAP_ALLOWED_MAIL_DOMAIN" "sebi.gov.in"
set_env_value "KEYCLOAK_REQUIRE_LDAP_OBJECT_GUID" "true"
set_env_value "KEYCLOAK_REQUIRE_LOCAL_EMAIL_VERIFIED" "false"
set_env_value "KEYCLOAK_LOGOUT_REDIRECT_URL" "/signin"
set_env_value "REDIS_URL" "redis://redis:6379/0"
set_env_value "NO_PROXY" "localhost,127.0.0.1,${PUBLIC_HOST},xyne-db,redis,xyne-redis,vespa,keycloak,xyne-keycloak,xyne-app,app,xyne-app-sync,app-sync,xyne-nginx,nginx,livekit,loki,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.local"
set_env_value "no_proxy" "localhost,127.0.0.1,${PUBLIC_HOST},xyne-db,redis,xyne-redis,vespa,keycloak,xyne-keycloak,xyne-app,app,xyne-app-sync,app-sync,xyne-nginx,nginx,livekit,loki,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.local"

printf '[ldap-start] Removing temporary containers from the manual host-network test\n'
for container in keycloak xyne-search xyne-postgres xyne-redis; do
  docker rm -f "${container}" >/dev/null 2>&1 || true
done

# start.sh and docker-compose.app.yml intentionally use xynehq/xyne:latest.
# Retag only after all air-gap images have already been loaded, then prevent
# start.sh from reloading an older application image from the bundle.
docker tag "${SOURCE_IMAGE}" xynehq/xyne:latest

printf '[ldap-start] Starting the standard Nginx/Compose deployment at %s\n' "${PUBLIC_URL}"
runtime_start="$(mktemp "${SCRIPT_DIR}/.start-keycloak-ldap-runtime.XXXXXX.sh")"
trap 'rm -f "${runtime_start}"' EXIT
sed \
  -e 's|XYNE_SEBI_CA_DOCKERFILE="Dockerfile.xyne-sebi-ca"|XYNE_SEBI_CA_DOCKERFILE="Dockerfile.xyne-sebi-ca-keycloak-ldap"|' \
  -e 's|set_env_value "KEYCLOAK_LOGOUT_REDIRECT_URL" "/auth"|set_env_value "KEYCLOAK_LOGOUT_REDIRECT_URL" "/signin"|' \
  -e "s|set_env_value \"KEYCLOAK_IMAGE\" \"quay.io/keycloak/keycloak:26.0\"|set_env_value \"KEYCLOAK_IMAGE\" \"${KEYCLOAK_LDAP_IMAGE}\"|" \
  start.sh > "${runtime_start}"
chmod +x "${runtime_start}"

XYNE_PUBLIC_URL="${PUBLIC_URL}" \
XYNE_SKIP_IMAGE_LOAD=true \
"${runtime_start}"
