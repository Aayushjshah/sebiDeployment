#!/usr/bin/env bash
set -uo pipefail

IPS=(
  10.52.23.18
  10.52.23.19
  10.113.23.18
  10.113.23.19
)

OUT_DIR="certs/ldap-$(date +%Y%m%d-%H%M%S)"
BUNDLE="${OUT_DIR}/sebi-ldap-ca-bundle.pem"

mkdir -p "${OUT_DIR}"
touch "${BUNDLE}"

declare -A fingerprint_owner

for ip in "${IPS[@]}"; do
  name="${ip//./-}"
  raw="${OUT_DIR}/${name}.raw"
  cert="${OUT_DIR}/${name}.pem"

  echo
  echo "Testing ${ip}:636..."

  docker run --rm \
    --network xyne \
    --entrypoint sh \
    vespaengine/vespa:latest \
    -lc "timeout 12 openssl s_client -connect ${ip}:636 -showcerts </dev/null 2>/dev/null" \
    > "${raw}" 2>/dev/null || true

  sed -n \
    '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    "${raw}" > "${cert}"

  if ! openssl x509 -in "${cert}" -noout >/dev/null 2>&1; then
    echo "[FAIL] No readable certificate received from ${ip}:636"
    rm -f "${cert}"
    continue
  fi

  fingerprint="$(
    openssl x509 -in "${cert}" -noout -fingerprint -sha256 |
      cut -d= -f2
  )"

  subject="$(openssl x509 -in "${cert}" -noout -subject)"
  issuer="$(openssl x509 -in "${cert}" -noout -issuer)"
  san="$(
    openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null |
      tail -n +2 |
      tr '\n' ' '
  )"

  echo "[PASS] IP:          ${ip}"
  echo "       Fingerprint: ${fingerprint}"
  echo "       ${subject}"
  echo "       ${issuer}"
  echo "       SAN: ${san:-not present}"

  if [[ -n "${fingerprint_owner[$fingerprint]:-}" ]]; then
    echo "       Same certificate as ${fingerprint_owner[$fingerprint]}"
  else
    fingerprint_owner["${fingerprint}"]="${ip}"
    cat "${cert}" >> "${BUNDLE}"
    printf '\n' >> "${BUNDLE}"
  fi
done

echo
echo "Unique certificate bundle: ${BUNDLE}"
echo "Certificates found: ${#fingerprint_owner[@]}"
