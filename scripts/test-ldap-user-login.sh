#!/usr/bin/env bash

# Test an actual end-user bind without displaying or storing the password.
# This is distinct from the service-account bind used for directory searches.

set -uo pipefail

LDAP_HOST="${LDAP_HOST:-10.52.23.18}"
LDAP_PORT="${LDAP_PORT:-636}"
LDAP_DOMAIN="${LDAP_DOMAIN:-SEBIP.GOV.IN}"
LDAP_389_MODE="${LDAP_389_MODE:-plain}"
LDAP_ALLOW_INSECURE="${LDAP_ALLOW_INSECURE:-false}"
LDAP_TLS_REQCERT="${LDAP_TLS_REQCERT:-demand}"
LDAP_CONNECT_TIMEOUT="${LDAP_CONNECT_TIMEOUT:-5}"

password_file=""
cleanup() {
  [ -z "${password_file}" ] || rm -f -- "${password_file}"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/test-ldap-user-login.sh USERNAME

By default USERNAME is converted to USERNAME@SEBIP.GOV.IN. Override the exact
bind identity if the directory requires a DN or another format:

  LDAP_USER_BIND_ID='CN=User Name,OU=USERS,...' \
    ./scripts/test-ldap-user-login.sh officer123

Relevant variables: LDAP_HOST, LDAP_PORT, LDAP_DOMAIN, LDAP_USER_PASSWORD,
LDAP_USER_BIND_ID, LDAP_389_MODE, and LDAP_TLS_REQCERT.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; fail "USERNAME is required." ;;
esac

command -v ldapwhoami >/dev/null 2>&1 || fail \
  "ldapwhoami is required (ldap-utils on Debian/Ubuntu; openldap-clients on RHEL)."

username="$1"
bind_id="${LDAP_USER_BIND_ID:-${username}@${LDAP_DOMAIN}}"
case "${LDAP_PORT}" in
  389) uri="ldap://${LDAP_HOST}:389" ;;
  636) uri="ldaps://${LDAP_HOST}:636" ;;
  *) fail "LDAP_PORT must be 389 or 636." ;;
esac
case "${LDAP_389_MODE}" in
  plain|starttls) ;;
  *) fail "LDAP_389_MODE must be plain or starttls." ;;
esac
if [ "${LDAP_PORT}" = "389" ] && [ "${LDAP_389_MODE}" = "plain" ] && \
   [ "${LDAP_ALLOW_INSECURE}" != "true" ]; then
  fail "Refusing an end-user bind over unencrypted port 389. Use LDAP_389_MODE=starttls or explicitly set LDAP_ALLOW_INSECURE=true."
fi

if [ -z "${LDAP_USER_PASSWORD:-}" ]; then
  [ -t 0 ] || fail "LDAP_USER_PASSWORD is unset and no interactive terminal is available."
  read -r -s -p "LDAP password for ${bind_id}: " LDAP_USER_PASSWORD
  printf '\n'
fi
[ -n "${LDAP_USER_PASSWORD:-}" ] || fail "Password cannot be empty."

password_file="$(mktemp "${TMPDIR:-/tmp}/ldap-user-password.XXXXXX")" || \
  fail "Could not create password file."
chmod 600 "${password_file}"
printf '%s' "${LDAP_USER_PASSWORD}" >"${password_file}"
unset LDAP_USER_PASSWORD

ldap_args=(
  -x
  -o "nettimeout=${LDAP_CONNECT_TIMEOUT}"
  -H "${uri}"
  -D "${bind_id}"
  -y "${password_file}"
)
if [ "${LDAP_PORT}" = "389" ] && [ "${LDAP_389_MODE}" = "starttls" ]; then
  ldap_args+=(-ZZ)
fi

printf '[TEST] End-user bind to %s as %s\n' "${uri}" "${bind_id}"
if LDAPTLS_REQCERT="${LDAP_TLS_REQCERT}" ldapwhoami "${ldap_args[@]}"; then
  printf '[PASS] End-user authentication succeeded\n'
else
  printf '[FAIL] End-user authentication failed\n' >&2
  exit 1
fi
