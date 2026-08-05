#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
REALM="${KEYCLOAK_REALM:-xyne-shared}"
PROVIDER_NAME="${KEYCLOAK_LDAP_PROVIDER_NAME:-SEBI LDAP}"
CONTAINER="${KEYCLOAK_CONTAINER:-xyne-keycloak}"
BACKUP_PATH="/tmp/xyne-keycloak-ldap-component.json"
KCADM="/opt/keycloak/bin/kcadm.sh"

case "${MODE}" in
  disable|restore) ;;
  *)
    printf 'Usage: %s disable|restore\n' "$0" >&2
    exit 2
    ;;
esac

docker exec \
  -e GUARD_MODE="${MODE}" \
  -e GUARD_REALM="${REALM}" \
  -e GUARD_PROVIDER_NAME="${PROVIDER_NAME}" \
  -e GUARD_BACKUP_PATH="${BACKUP_PATH}" \
  -e GUARD_KCADM="${KCADM}" \
  "${CONTAINER}" sh -eu -c '
    "$GUARD_KCADM" config credentials \
      --server http://127.0.0.1:8080/keycloak \
      --realm master \
      --user "$KEYCLOAK_ADMIN" \
      --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

    if [ "$GUARD_MODE" = restore ]; then
      if [ ! -s "$GUARD_BACKUP_PATH" ]; then
        echo "[warn] No LDAP component backup was found; nothing to restore"
        exit 0
      fi
      component_id=$(sed -n "s/.*\"id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$GUARD_BACKUP_PATH" | head -n 1)
      [ -n "$component_id" ] || { echo "Could not read LDAP component id from backup" >&2; exit 1; }
      "$GUARD_KCADM" update "components/$component_id" -r "$GUARD_REALM" -f "$GUARD_BACKUP_PATH"
      rm -f "$GUARD_BACKUP_PATH"
      echo "[start] Restored Keycloak LDAP provider"
      exit 0
    fi

    summary=$("$GUARD_KCADM" get components -r "$GUARD_REALM" \
      -q "name=$GUARD_PROVIDER_NAME" \
      -q type=org.keycloak.storage.UserStorageProvider \
      --fields id,name,providerId)
    component_id=$(printf "%s\n" "$summary" | sed -n "s/.*\"id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)

    if [ -z "$component_id" ]; then
      echo "[info] LDAP provider $GUARD_PROVIDER_NAME is not configured; bootstrap will continue normally"
      exit 0
    fi

    "$GUARD_KCADM" get "components/$component_id" -r "$GUARD_REALM" > "$GUARD_BACKUP_PATH"
    cp "$GUARD_BACKUP_PATH" "${GUARD_BACKUP_PATH}.disabled"
    sed -i "0,/\"enabled\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\"true\"[[:space:]]*\]/s//\"enabled\" : [ \"false\" ]/" \
      "${GUARD_BACKUP_PATH}.disabled"

    if cmp -s "$GUARD_BACKUP_PATH" "${GUARD_BACKUP_PATH}.disabled"; then
      rm -f "${GUARD_BACKUP_PATH}.disabled"
      echo "[info] LDAP provider is already disabled"
      exit 0
    fi

    "$GUARD_KCADM" update "components/$component_id" -r "$GUARD_REALM" \
      -f "${GUARD_BACKUP_PATH}.disabled"
    rm -f "${GUARD_BACKUP_PATH}.disabled"
    echo "[start] Temporarily disabled Keycloak LDAP provider for local bootstrap"
  '
