#!/bin/bash
set -e

KEYSTORE="/etc/java/java-17-openjdk/java-17-openjdk-17.0.18.0.8-1.el8.x86_64/lib/security/cacerts"

echo "[vespa-init] Fetching CDAC certificate..."
openssl s_client \
  -proxy 10.201.6.100:1080 \
  -servername apis.airawat.cdac.in \
  -connect apis.airawat.cdac.in:443 \
  -showcerts </dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  > /tmp/cdac.pem

if [ ! -s /tmp/cdac.pem ]; then
  echo "[vespa-init] WARNING: cert fetch failed, continuing anyway..."
else
  keytool -import -trustcacerts \
    -alias cdac-airawat \
    -file /tmp/cdac.pem \
    -keystore "$KEYSTORE" \
    -storepass changeit \
    -noprompt 2>/dev/null \
    && echo "[vespa-init] Cert imported" \
    || echo "[vespa-init] Cert already exists, skipping"
fi

exec /usr/local/bin/start-container.sh
