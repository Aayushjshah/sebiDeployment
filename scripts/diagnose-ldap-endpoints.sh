#!/usr/bin/env bash

# Read-only LDAP/AD endpoint diagnostic for the SEBI environment.
# Tests all configured hosts on LDAPS 636 and LDAP 389 with required StartTLS,
# queries one known user, and compares objectGUID across successful replicas.

set -uo pipefail

LDAP_HOSTS="${LDAP_HOSTS:-10.52.23.18 10.52.23.19 10.113.23.18 10.113.23.19}"
LDAP_BIND_USER="${LDAP_BIND_USER:-saaipoc}"
LDAP_BASE_DN="${LDAP_BASE_DN:-OU=USERS,OU=PROD,DC=sebip,DC=gov,DC=in}"
LDAP_PASSWORD_FILE="${LDAP_PASSWORD_FILE:-/run/secrets/ldap-bind-password}"
LDAP_CONNECT_TIMEOUT="${LDAP_CONNECT_TIMEOUT:-5}"
LDAP_TEST_PLAIN_389="${LDAP_TEST_PLAIN_389:-false}"

test_user="${1:-${LDAP_TEST_USER:-1289}}"
temp_dir=""
active_password_file=""
created_password_file="false"
encrypted_successes=0
failures=0

declare -a summary_rows=()
declare -a guid_endpoints=()
declare -a guid_values=()

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/diagnose-ldap-endpoints.sh [TEST_USERNAME]

Defaults:
  TEST_USERNAME       1289
  LDAP hosts          10.52.23.18, 10.52.23.19,
                      10.113.23.18, 10.113.23.19
  Tests               LDAPS 636 and LDAP 389 with required StartTLS
  Certificate policy  Verification disabled for this diagnostic only

Environment overrides:
  LDAP_HOSTS                 Space-separated host/IP list
  LDAP_BIND_USER             Bind identity, default saaipoc
  LDAP_BASE_DN               Users search base
  LDAP_PASSWORD_FILE         Password file, default /run/secrets/ldap-bind-password
  LDAP_PASSWORD              Password value if no readable password file exists
  LDAP_CONNECT_TIMEOUT       Per-connection timeout in seconds, default 5
  LDAP_TEST_USER             Test username when no positional argument is given
  LDAP_TEST_PLAIN_389=true   Also test an unencrypted simple bind on port 389

The script never prints the bind password. Paste the complete diagnostic output
back into the conversation for analysis.
EOF
}

fail() {
  printf '[FATAL] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ "${created_password_file}" = "true" ] && [ -n "${active_password_file}" ]; then
    rm -f -- "${active_password_file}"
  fi
  if [ -n "${temp_dir}" ] && [ -d "${temp_dir}" ]; then
    rm -rf -- "${temp_dir}"
  fi
}
trap cleanup EXIT HUP INT TERM

escape_filter_value() {
  local value="$1"
  value="${value//\\/\\5c}"
  value="${value//\*/\\2a}"
  value="${value//\(/\\28}"
  value="${value//\)/\\29}"
  printf '%s' "${value}"
}

prepare_password_file() {
  if [ -r "${LDAP_PASSWORD_FILE}" ]; then
    active_password_file="${LDAP_PASSWORD_FILE}"
    printf '[INFO] Password source: readable file %s\n' "${LDAP_PASSWORD_FILE}"
    return
  fi

  active_password_file="${temp_dir}/bind-password"
  created_password_file="true"
  umask 077

  if [ -n "${LDAP_PASSWORD:-}" ]; then
    printf '%s' "${LDAP_PASSWORD}" >"${active_password_file}"
    unset LDAP_PASSWORD
    printf '[INFO] Password source: temporary protected file from LDAP_PASSWORD\n'
    return
  fi

  [ -t 0 ] || fail "Password file is unreadable and no interactive terminal is available."
  printf 'Enter LDAP bind password for %s: ' "${LDAP_BIND_USER}"
  stty -echo
  IFS= read -r password
  stty echo
  printf '\n'
  [ -n "${password}" ] || fail "LDAP bind password cannot be empty."
  printf '%s' "${password}" >"${active_password_file}"
  unset password
  printf '[INFO] Password source: temporary protected prompt file\n'
}

tcp_test() {
  local host="$1"
  local port="$2"

  if command -v nc >/dev/null 2>&1; then
    nc -z -w "${LDAP_CONNECT_TIMEOUT}" "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${LDAP_CONNECT_TIMEOUT}" bash -c ">/dev/tcp/${host}/${port}" \
      >/dev/null 2>&1
    return $?
  fi

  return 2
}

print_selected_attributes() {
  local output_file="$1"
  grep -E '^(dn|cn|displayName|sAMAccountName|userPrincipalName|objectGUID)(::)?: ' \
    "${output_file}" || true
}

record_guid() {
  local endpoint="$1"
  local output_file="$2"
  local guid

  guid="$(awk 'BEGIN { IGNORECASE=1 } /^objectGUID(::)?: / { print $2; exit }' \
    "${output_file}")"
  if [ -n "${guid}" ]; then
    guid_endpoints+=("${endpoint}")
    guid_values+=("${guid}")
  fi
}

ldap_test() {
  local host="$1"
  local port="$2"
  local mode="$3"
  local label="$4"
  local uri output_file error_file status entry_count escaped_user endpoint
  local -a args

  endpoint="${host}:${port}/${mode}"
  output_file="${temp_dir}/${host//./_}-${port}-${mode}.out"
  error_file="${temp_dir}/${host//./_}-${port}-${mode}.err"
  escaped_user="$(escape_filter_value "${test_user}")"

  if [ "${mode}" = "ldaps" ]; then
    uri="ldaps://${host}:${port}"
  else
    uri="ldap://${host}:${port}"
  fi

  args=(
    -LLL -x
    -o "nettimeout=${LDAP_CONNECT_TIMEOUT}"
    -H "${uri}"
    -D "${LDAP_BIND_USER}"
    -y "${active_password_file}"
    -b "${LDAP_BASE_DN}"
    -s sub
  )
  if [ "${mode}" = "starttls" ]; then
    args+=(-ZZ)
  fi

  printf '\n[TEST] %s %s\n' "${label}" "${endpoint}"
  LDAPTLS_REQCERT=never ldapsearch "${args[@]}" \
    "(&(objectClass=person)(sAMAccountName=${escaped_user}))" \
    dn cn displayName sAMAccountName userPrincipalName objectGUID \
    >"${output_file}" 2>"${error_file}"
  status=$?

  if [ "${status}" -eq 0 ]; then
    entry_count="$(grep -c '^dn: ' "${output_file}" || true)"
    if [ "${entry_count}" -eq 1 ]; then
      printf '[PASS] Bind/search succeeded; exactly one user returned.\n'
      summary_rows+=("${host}|${port}|${mode}|PASS|one user")
      if [ "${mode}" != "plain" ]; then
        encrypted_successes=$((encrypted_successes + 1))
      fi
      print_selected_attributes "${output_file}"
      record_guid "${endpoint}" "${output_file}"
    else
      printf '[WARN] Bind/search succeeded but returned %s entries.\n' "${entry_count}"
      summary_rows+=("${host}|${port}|${mode}|WARN|${entry_count} users")
      failures=$((failures + 1))
      print_selected_attributes "${output_file}"
    fi
    return
  fi

  printf '[FAIL] ldapsearch exit code %s\n' "${status}"
  if [ -s "${error_file}" ]; then
    tail -n 8 "${error_file}"
  fi
  summary_rows+=("${host}|${port}|${mode}|FAIL|ldapsearch exit ${status}")
  failures=$((failures + 1))
}

print_summary() {
  local row host port mode result detail index unique_count

  printf '\n================ ENDPOINT SUMMARY ================\n'
  printf '%-16s %-6s %-10s %-7s %s\n' "HOST" "PORT" "MODE" "RESULT" "DETAIL"
  for row in "${summary_rows[@]}"; do
    IFS='|' read -r host port mode result detail <<<"${row}"
    printf '%-16s %-6s %-10s %-7s %s\n' \
      "${host}" "${port}" "${mode}" "${result}" "${detail}"
  done

  printf '\n================ objectGUID COMPARISON ================\n'
  if [ "${#guid_values[@]}" -eq 0 ]; then
    printf '[FAIL] No objectGUID was returned by any successful endpoint.\n'
  else
    for ((index = 0; index < ${#guid_values[@]}; index++)); do
      printf '%-34s %s\n' "${guid_endpoints[$index]}" "${guid_values[$index]}"
    done
    unique_count="$(printf '%s\n' "${guid_values[@]}" | sort -u | wc -l | tr -d ' ')"
    if [ "${unique_count}" -eq 1 ]; then
      printf '[PASS] All successful endpoints returned the same objectGUID.\n'
    else
      printf '[FAIL] Successful endpoints returned %s different objectGUID values.\n' \
        "${unique_count}"
      failures=$((failures + 1))
    fi
  fi

  printf '\nEncrypted LDAP successes: %s\n' "${encrypted_successes}"
  printf 'Warnings/failures:        %s\n' "${failures}"
  printf 'Certificate verification was disabled only for this diagnostic.\n'
}

main() {
  local host port

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  command -v ldapsearch >/dev/null 2>&1 || fail \
    "ldapsearch is required (openldap-clients on RHEL; ldap-utils on Debian)."
  command -v grep >/dev/null 2>&1 || fail "grep is required."
  command -v awk >/dev/null 2>&1 || fail "awk is required."

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ldap-endpoint-diagnostic.XXXXXX")" || \
    fail "Could not create temporary directory."
  chmod 700 "${temp_dir}"
  prepare_password_file

  printf '\n================ LDAP ENDPOINT DIAGNOSTIC ================\n'
  printf 'Hosts:              %s\n' "${LDAP_HOSTS}"
  printf 'Bind identity:      %s\n' "${LDAP_BIND_USER}"
  printf 'Users Base DN:      %s\n' "${LDAP_BASE_DN}"
  printf 'Test username:      %s\n' "${test_user}"
  printf 'Timeout:            %ss\n' "${LDAP_CONNECT_TIMEOUT}"
  printf 'TLS CA verification: disabled for diagnostic\n'

  for host in ${LDAP_HOSTS}; do
    for port in 389 636; do
      if tcp_test "${host}" "${port}"; then
        printf '[TCP PASS] %s:%s reachable\n' "${host}" "${port}"
      else
        status=$?
        if [ "${status}" -eq 2 ]; then
          printf '[TCP SKIP] %s:%s; install nc or timeout for TCP-only check\n' \
            "${host}" "${port}"
        else
          printf '[TCP FAIL] %s:%s unreachable within %ss\n' \
            "${host}" "${port}" "${LDAP_CONNECT_TIMEOUT}"
        fi
      fi
    done

    ldap_test "${host}" 636 ldaps "LDAPS"
    ldap_test "${host}" 389 starttls "LDAP with required StartTLS"

    if [ "${LDAP_TEST_PLAIN_389}" = "true" ]; then
      printf '\n[WARNING] Testing an unencrypted simple bind on port 389.\n'
      ldap_test "${host}" 389 plain "Plain LDAP"
    fi
  done

  print_summary

  if [ "${encrypted_successes}" -eq 0 ]; then
    printf '\n[FINAL FAIL] No encrypted LDAP endpoint succeeded.\n' >&2
    exit 1
  fi
  printf '\n[FINAL] Diagnostic completed. Paste this complete output for analysis.\n'
}

main "$@"
