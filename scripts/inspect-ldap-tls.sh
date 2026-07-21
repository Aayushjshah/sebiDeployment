#!/usr/bin/env bash

# Inspect the TLS certificates presented by every LDAP destination. No LDAP
# username or password is needed. Run this from every application VM.

set -uo pipefail

LDAP_HOSTS="${LDAP_HOSTS:-10.52.23.18 10.52.23.19 10.113.23.18 10.113.23.19}"
LDAP_TLS_PORTS="${LDAP_TLS_PORTS:-636}"
LDAP_CONNECT_TIMEOUT="${LDAP_CONNECT_TIMEOUT:-5}"
LDAP_389_MODE="${LDAP_389_MODE:-starttls}"

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/inspect-ldap-tls.sh

Defaults to direct TLS on port 636 for all four LDAP destinations. To inspect
StartTLS on port 389 as well:

  LDAP_TLS_PORTS="389 636" ./scripts/inspect-ldap-tls.sh

This verifies against the VM's current CA trust. A certificate failure means
the organization's CA or correct DNS server name may still be required.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; fail "Unknown argument: $1" ;;
esac

command -v openssl >/dev/null 2>&1 || fail "openssl is required."
command -v timeout >/dev/null 2>&1 && timeout_command="timeout" || timeout_command=""

passed=0
failed=0

for host in ${LDAP_HOSTS}; do
  for port in ${LDAP_TLS_PORTS}; do
    openssl_args=(s_client -connect "${host}:${port}" -showcerts -verify_return_error)
    case "${port}" in
      636) ;;
      389)
        [ "${LDAP_389_MODE}" = "starttls" ] || fail \
          "Port 389 TLS inspection requires LDAP_389_MODE=starttls."
        openssl_args+=(-starttls ldap)
        ;;
      *) fail "LDAP_TLS_PORTS supports only 389 and 636." ;;
    esac

    printf '\n[TEST] TLS certificate from %s:%s\n' "${host}" "${port}"
    if [ -n "${timeout_command}" ]; then
      certificate="$(${timeout_command} "${LDAP_CONNECT_TIMEOUT}" openssl "${openssl_args[@]}" </dev/null 2>&1)"
      status=$?
    else
      certificate="$(openssl "${openssl_args[@]}" </dev/null 2>&1)"
      status=$?
    fi

    printf '%s\n' "${certificate}" | \
      sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | \
      openssl x509 -noout \
      -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
    verify_line="$(printf '%s\n' "${certificate}" | sed -n '/Verify return code:/p' | tail -n 1)"
    [ -z "${verify_line}" ] || printf '%s\n' "${verify_line}"

    if [ "${status}" -eq 0 ]; then
      printf '[PASS] TLS handshake and trust verification succeeded\n'
      passed=$((passed + 1))
    else
      printf '[FAIL] TLS handshake or certificate verification failed\n' >&2
      verify_errors="$(printf '%s\n' "${certificate}" | sed -n '/verify error/p;/Verify return code:/p' | tail -n 4)"
      [ -z "${verify_errors}" ] || printf '%s\n' "${verify_errors}" >&2
      failed=$((failed + 1))
    fi
  done
done

printf '\nSummary: %s passed, %s failed\n' "${passed}" "${failed}"
[ "${failed}" -eq 0 ]
