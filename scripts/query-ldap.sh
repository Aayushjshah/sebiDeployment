#!/usr/bin/env bash

# Run common, read-only LDAP/Active Directory searches without placing the
# bind password on the command line. Run this script from an application VM.

set -uo pipefail

LDAP_HOST="${LDAP_HOST:-10.52.23.18}"
LDAP_PORT="${LDAP_PORT:-636}"
LDAP_BIND_USER="${LDAP_BIND_USER:-saaipoc}"
LDAP_BASE_DN="${LDAP_BASE_DN:-OU=USERS,OU=PROD,DC=sebip,DC=gov,DC=in}"
LDAP_TLS_REQCERT="${LDAP_TLS_REQCERT:-demand}"
LDAP_CONNECT_TIMEOUT="${LDAP_CONNECT_TIMEOUT:-5}"
LDAP_RESULT_LIMIT="${LDAP_RESULT_LIMIT:-20}"
LDAP_389_MODE="${LDAP_389_MODE:-plain}"
LDAP_ALLOW_INSECURE="${LDAP_ALLOW_INSECURE:-false}"

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
Usage: ./scripts/query-ldap.sh ACTION [VALUE]

Actions:
  people                 Sample person records
  users                  Sample Active Directory user records
  active-users           Users whose AD account is not disabled
  user IDENTIFIER        Find a user by login, UPN, employeeID, or mail
  attributes IDENTIFIER  Show all readable attributes for one user
  groups                 Sample group records
  group NAME             Find a group and list its members
  user-groups IDENTIFIER Show a user's memberOf values
  changed-since TIME     Persons changed since YYYYMMDDHHMMSSZ (UTC)
  custom FILTER          Run an explicitly supplied RFC 4515 LDAP filter
  sync-users             Paged query intended to inspect synchronization data

Important environment variables:
  LDAP_HOST              One LDAP destination (default: 10.52.23.18)
  LDAP_PORT              389 or 636 (default: 636)
  LDAP_BIND_USER         Service-account bind identity
  LDAP_BASE_DN           Search base
  LDAP_PASSWORD          Hidden prompt if omitted
  LDAP_RESULT_LIMIT      Maximum results for normal queries (default: 20)
  LDAP_389_MODE          plain or starttls (default: plain)
  LDAP_ALLOW_INSECURE    Must be true to bind over plain port 389
  LDAP_TLS_REQCERT       demand, allow, or never (default: demand)

Examples:
  ./scripts/query-ldap.sh people
  ./scripts/query-ldap.sh user officer123
  ./scripts/query-ldap.sh changed-since 20260721000000Z
  ./scripts/query-ldap.sh custom '(&(objectClass=person)(department=IT*))'
EOF
}

escape_filter_value() {
  # RFC 4515 escaping prevents a user-supplied identifier becoming a filter.
  local value="$1"
  value="${value//\\/\\5c}"
  value="${value//\*/\\2a}"
  value="${value//\(/\\28}"
  value="${value//\)/\\29}"
  printf '%s' "${value}"
}

require_value() {
  [ -n "${2:-}" ] || fail "Action '$1' requires a value."
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

command -v ldapsearch >/dev/null 2>&1 || fail \
  "ldapsearch is required (ldap-utils on Debian/Ubuntu; openldap-clients on RHEL)."

case "${LDAP_PORT}" in
  389) LDAP_URI="ldap://${LDAP_HOST}:389" ;;
  636) LDAP_URI="ldaps://${LDAP_HOST}:636" ;;
  *) fail "LDAP_PORT must be 389 or 636." ;;
esac

case "${LDAP_389_MODE}" in
  plain|starttls) ;;
  *) fail "LDAP_389_MODE must be plain or starttls." ;;
esac
if [ "${LDAP_PORT}" = "389" ] && [ "${LDAP_389_MODE}" = "plain" ] && \
   [ "${LDAP_ALLOW_INSECURE}" != "true" ]; then
  fail "Refusing a simple bind over unencrypted port 389. Use LDAP_389_MODE=starttls or explicitly set LDAP_ALLOW_INSECURE=true."
fi

if [ -z "${LDAP_PASSWORD:-}" ]; then
  [ -t 0 ] || fail "LDAP_PASSWORD is unset and no interactive terminal is available."
  read -r -s -p "LDAP password for ${LDAP_BIND_USER}: " LDAP_PASSWORD
  printf '\n'
fi
[ -n "${LDAP_PASSWORD:-}" ] || fail "LDAP password cannot be empty."

password_file="$(mktemp "${TMPDIR:-/tmp}/ldap-password.XXXXXX")" || \
  fail "Could not create password file."
chmod 600 "${password_file}"
printf '%s' "${LDAP_PASSWORD}" >"${password_file}"
unset LDAP_PASSWORD

action="${1:-}"
value="${2:-}"
[ -n "${action}" ] || { usage; exit 1; }

filter=""
attributes=(dn cn displayName sAMAccountName userPrincipalName employeeID mail department title manager memberOf whenChanged)
paged="false"

case "${action}" in
  people)
    filter='(objectClass=person)'
    ;;
  users)
    filter='(&(objectCategory=person)(objectClass=user))'
    ;;
  active-users)
    filter='(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
    attributes+=(userAccountControl accountExpires)
    ;;
  user|attributes|user-groups)
    require_value "${action}" "${value}"
    escaped_value="$(escape_filter_value "${value}")"
    filter="(&(objectClass=person)(|(sAMAccountName=${escaped_value})(userPrincipalName=${escaped_value})(employeeID=${escaped_value})(mail=${escaped_value})))"
    if [ "${action}" = "attributes" ]; then
      attributes=('*' '+')
    elif [ "${action}" = "user-groups" ]; then
      attributes=(dn cn sAMAccountName memberOf)
    fi
    ;;
  groups)
    filter='(objectClass=group)'
    attributes=(dn cn description member)
    ;;
  group)
    require_value "${action}" "${value}"
    escaped_value="$(escape_filter_value "${value}")"
    filter="(&(objectClass=group)(|(cn=${escaped_value})(sAMAccountName=${escaped_value})))"
    attributes=(dn cn description member)
    ;;
  changed-since)
    require_value "${action}" "${value}"
    [[ "${value}" =~ ^[0-9]{14}Z$ ]] || fail "TIME must use UTC format YYYYMMDDHHMMSSZ."
    filter="(&(objectClass=person)(whenChanged>=${value}))"
    ;;
  custom)
    require_value "${action}" "${value}"
    filter="${value}"
    ;;
  sync-users)
    filter='(&(objectCategory=person)(objectClass=user))'
    attributes+=(objectGUID objectSid userAccountControl accountExpires uSNChanged)
    paged="true"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "Unknown action: ${action}"
    ;;
esac

ldap_args=(
  -LLL -x
  -o "nettimeout=${LDAP_CONNECT_TIMEOUT}"
  -H "${LDAP_URI}"
  -D "${LDAP_BIND_USER}"
  -y "${password_file}"
  -b "${LDAP_BASE_DN}"
  -s sub
)

if [ "${LDAP_PORT}" = "389" ] && [ "${LDAP_389_MODE}" = "starttls" ]; then
  ldap_args+=(-ZZ)
fi
if [ "${paged}" = "true" ]; then
  ldap_args+=(-E pr=500/noprompt)
else
  ldap_args+=(-z "${LDAP_RESULT_LIMIT}")
fi

printf 'Server: %s\nBase:   %s\nFilter: %s\n\n' "${LDAP_URI}" "${LDAP_BASE_DN}" "${filter}"
LDAPTLS_REQCERT="${LDAP_TLS_REQCERT}" ldapsearch \
  "${ldap_args[@]}" "${filter}" "${attributes[@]}"
ldap_status=$?

# A normal limited query may return LDAP sizeLimitExceeded (ldapsearch exit 4)
# after printing the requested number of entries. That is successful sampling.
if [ "${ldap_status}" -eq 4 ] && [ "${paged}" = "false" ]; then
  printf '\n[INFO] Result display stopped at LDAP_RESULT_LIMIT=%s.\n' "${LDAP_RESULT_LIMIT}" >&2
  exit 0
fi
exit "${ldap_status}"
