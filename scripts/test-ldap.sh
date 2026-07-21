#!/usr/bin/env bash

# Validate TCP connectivity, an LDAP bind, and a search under the configured
# Base DN. Run this script on each application VM that must reach LDAP.
#
# The bind password is never stored in this file or passed on a command line.
# Set LDAP_PASSWORD in the environment or enter it at the hidden prompt.

set -uo pipefail

LDAP_HOSTS="${LDAP_HOSTS:-10.52.23.18 10.52.23.19 10.113.23.18 10.113.23.19}"
LDAP_PORTS="${LDAP_PORTS:-636}"
LDAP_BIND_USER="${LDAP_BIND_USER:-saaipoc}"
LDAP_BASE_DN="${LDAP_BASE_DN:-OU=USERS,OU=PROD,DC=sebip,DC=gov,DC=in}"
LDAP_SEARCH_FILTER="${LDAP_SEARCH_FILTER:-(&(objectClass=person))}"
LDAP_CONNECT_TIMEOUT="${LDAP_CONNECT_TIMEOUT:-5}"
LDAP_TLS_REQCERT="${LDAP_TLS_REQCERT:-demand}"
LDAP_389_MODE="${LDAP_389_MODE:-plain}"
LDAP_ALLOW_INSECURE="${LDAP_ALLOW_INSECURE:-false}"
password_file=""
search_output=""

usage() {
  cat <<'EOF'
Usage: ./scripts/test-ldap.sh

Run this script separately on every application VM that needs LDAP access.

  -h, --help Show this help.

Configuration can be overridden with environment variables:
  LDAP_HOSTS            Space-separated LDAP destination IPs
  LDAP_PORTS            Ports to test, default: 636
  LDAP_BIND_USER        Bind identity, default: saaipoc
  LDAP_BASE_DN          Search Base DN
  LDAP_SEARCH_FILTER    Search filter, default: (&(objectClass=person))
  LDAP_389_MODE         plain or starttls (default: plain)
  LDAP_ALLOW_INSECURE   Must be true to bind over plain port 389
  LDAP_TLS_REQCERT      TLS certificate policy: demand, allow, or never
  LDAP_PASSWORD         Bind password; hidden prompt if omitted

Examples:
  ./scripts/test-ldap.sh
  LDAP_TLS_REQCERT=allow ./scripts/test-ldap.sh
  LDAP_PORTS=389 LDAP_389_MODE=starttls ./scripts/test-ldap.sh
EOF
}

cleanup() {
  [ -z "${password_file}" ] || rm -f -- "${password_file}"
  [ -z "${search_output}" ] || rm -f -- "${search_output}"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

get_password() {
  if [ -z "${LDAP_PASSWORD:-}" ]; then
    if [ ! -t 0 ]; then
      fail "LDAP_PASSWORD is unset and no interactive terminal is available."
    fi
    read -r -s -p "LDAP password for ${LDAP_BIND_USER}: " LDAP_PASSWORD
    printf '\n'
  fi
  [ -n "${LDAP_PASSWORD:-}" ] || fail "LDAP password cannot be empty."
}

run_local_tests() {
  local host port scheme uri ldap_status first_dn
  local -a ldap_args
  local passed=0
  local failed=0

  command -v ldapsearch >/dev/null 2>&1 || fail \
    "ldapsearch is required (ldap-utils on Debian/Ubuntu; openldap-clients on RHEL)."
  case "${LDAP_389_MODE}" in
    plain|starttls) ;;
    *) fail "LDAP_389_MODE must be plain or starttls." ;;
  esac
  if [ "${LDAP_PORTS}" = "389" ] && [ "${LDAP_389_MODE}" = "plain" ] && \
     [ "${LDAP_ALLOW_INSECURE}" != "true" ]; then
    fail "Refusing a simple bind over unencrypted port 389. Use LDAP_389_MODE=starttls or explicitly set LDAP_ALLOW_INSECURE=true."
  fi
  get_password

  password_file="$(mktemp "${TMPDIR:-/tmp}/ldap-password.XXXXXX")" || \
    fail "Could not create password file."
  chmod 600 "${password_file}"
  printf '%s' "${LDAP_PASSWORD}" >"${password_file}"
  unset LDAP_PASSWORD

  search_output="$(mktemp "${TMPDIR:-/tmp}/ldap-search.XXXXXX")" || \
    fail "Could not create search output."

  printf 'LDAP server(s): %s\n' "${LDAP_HOSTS}"
  printf 'Ports:          %s\n' "${LDAP_PORTS}"
  printf 'Bind user:      %s\n' "${LDAP_BIND_USER}"
  printf 'Base DN:        %s\n\n' "${LDAP_BASE_DN}"

  for host in ${LDAP_HOSTS}; do
    for port in ${LDAP_PORTS}; do
      case "${port}" in
        389) scheme="ldap" ;;
        636) scheme="ldaps" ;;
        *)
          printf '[FAIL] %s:%s - unsupported port (expected 389 or 636)\n' "${host}" "${port}" >&2
          failed=$((failed + 1))
          continue
          ;;
      esac

      if [ "${port}" = "389" ] && [ "${LDAP_389_MODE}" = "plain" ] && \
         [ "${LDAP_ALLOW_INSECURE}" != "true" ]; then
        printf '[FAIL] %s:%s - refusing an unencrypted simple bind\n' "${host}" "${port}" >&2
        failed=$((failed + 1))
        continue
      fi

      uri="${scheme}://${host}:${port}"
      printf '[TEST] %s\n' "${uri}"

      if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w "${LDAP_CONNECT_TIMEOUT}" "${host}" "${port}" >/dev/null 2>&1; then
          printf '[FAIL] %s - TCP connection failed\n' "${uri}" >&2
          failed=$((failed + 1))
          continue
        fi
        printf '       TCP connection succeeded\n'
      fi

      : >"${search_output}"
      ldap_args=(
        -LLL -x
        -o "nettimeout=${LDAP_CONNECT_TIMEOUT}"
        -H "${uri}"
        -D "${LDAP_BIND_USER}"
        -y "${password_file}"
        -b "${LDAP_BASE_DN}"
        -s sub -z 1
      )
      if [ "${port}" = "389" ] && [ "${LDAP_389_MODE}" = "starttls" ]; then
        ldap_args+=(-ZZ)
      fi
      LDAPTLS_REQCERT="${LDAP_TLS_REQCERT}" ldapsearch \
        "${ldap_args[@]}" "${LDAP_SEARCH_FILTER}" dn \
        >"${search_output}" 2>&1
      ldap_status=$?

      # Exit 4 means the requested one-entry size limit was reached. The bind,
      # Base DN lookup, and search nevertheless succeeded.
      if [ "${ldap_status}" -eq 0 ] || [ "${ldap_status}" -eq 4 ]; then
        first_dn="$(sed -n 's/^dn: /dn: /p' "${search_output}" | head -n 1)"
        printf '[PASS] %s - bind and search succeeded%s\n' \
          "${uri}" "${first_dn:+ (${first_dn})}"
        passed=$((passed + 1))
      else
        printf '[FAIL] %s - bind/search failed (ldapsearch exit %s)\n' \
          "${uri}" "${ldap_status}" >&2
        sed 's/^/       /' "${search_output}" >&2
        failed=$((failed + 1))
      fi
    done
  done

  printf '\nSummary: %s passed, %s failed\n' "${passed}" "${failed}"
  [ "${failed}" -eq 0 ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
  shift
done

run_local_tests
