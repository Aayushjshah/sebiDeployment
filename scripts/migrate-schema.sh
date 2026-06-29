#!/usr/bin/env bash
# migrate-schema.sh — Drizzle schema-migration helper for the xyne-app container.
# Wraps `bun run generate` + `bun run migrate` and the surrounding safety steps.
#
# Why this exists:
#   start.sh / start-v2.sh only run migrations on the FIRST boot (gated by the
#   /usr/src/app/server/storage/.xyne_initialized marker). On a subsequent code
#   upgrade — e.g. moving from xyne v1 → xyne-v2 — the marker already exists,
#   so the container starts WITHOUT applying new schema diffs and tables drift
#   from the current code's expectations. This script gives you a safe way to
#   run those steps explicitly on a running DEST.
#
# Modes:
#   backup    Snapshot Postgres before any schema change (delegates to migrate-psql.sh).
#   generate  Run `drizzle-kit generate` inside xyne-app to write migration SQL files.
#   inspect   List the generated migration files and print the first 200 lines of SQL.
#   apply     Run `drizzle-kit migrate` inside xyne-app to apply pending migrations.
#   status    Print the rows currently in drizzle.__drizzle_migrations (the journal).
#   reset     Delete the .xyne_initialized marker (so start-v2.sh re-runs migrations
#             on next container restart). Does NOT restart for you.
#   all       backup → generate → inspect → prompt → apply. Recommended for upgrades.
#
# Usage:
#   ./migrate-schema.sh backup   -o /data/DATA_BACKUP
#   ./migrate-schema.sh generate [-a xyne-app]
#   ./migrate-schema.sh inspect  [-a xyne-app]
#   ./migrate-schema.sh apply    [-a xyne-app]
#   ./migrate-schema.sh status   [-c xyne-db]
#   ./migrate-schema.sh reset    [-a xyne-app]
#   ./migrate-schema.sh all      -o /data/DATA_BACKUP [-a xyne-app] [-c xyne-db]
#
# Env defaults (override at the CLI):
#   XYNE_APP_CONTAINER=xyne-app
#   POSTGRES_CONTAINER=xyne-db
#   APP_WORKDIR=/usr/src/app/server   (Dockerfile.v2 WORKDIR — drizzle.config.ts lives here)
#   INIT_MARKER=/usr/src/app/server/storage/.xyne_initialized


set -euo pipefail


XYNE_APP_CONTAINER="${XYNE_APP_CONTAINER:-xyne-app}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-xyne-db}"
APP_WORKDIR="${APP_WORKDIR:-/usr/src/app/server}"
INIT_MARKER="${INIT_MARKER:-/usr/src/app/server/storage/.xyne_initialized}"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }


require_docker_container() {
 docker inspect "$1" >/dev/null 2>&1 || die "container '$1' not found (is the stack up?)"
}


cmd_backup() {
 local OPTIND=1
 local outdir=""
 while getopts ":o:c:" opt; do
   case "$opt" in
     o) outdir="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$outdir" ]] || die "usage: backup -o <output_dir> [-c <db_container>]"
 local sibling="$SCRIPT_DIR/migrate-psql.sh"
 [[ -x "$sibling" ]] || die "expected sibling helper at $sibling"
 log "Delegating to migrate-psql.sh backup..."
 POSTGRES_CONTAINER="$POSTGRES_CONTAINER" "$sibling" backup -o "$outdir"
}


cmd_generate() {
 local OPTIND=1
 while getopts ":a:" opt; do
   case "$opt" in
     a) XYNE_APP_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$XYNE_APP_CONTAINER"
 log "Running 'bun run generate' inside $XYNE_APP_CONTAINER (cwd=$APP_WORKDIR)..."
 docker exec -w "$APP_WORKDIR" "$XYNE_APP_CONTAINER" bun run generate
 log "Done. Inspect the new files with: $0 inspect"
}


cmd_inspect() {
 local OPTIND=1
 while getopts ":a:" opt; do
   case "$opt" in
     a) XYNE_APP_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$XYNE_APP_CONTAINER"
 log "Files in $APP_WORKDIR/migrations/:"
 docker exec -w "$APP_WORKDIR" "$XYNE_APP_CONTAINER" sh -c \
   "ls -la migrations/ 2>/dev/null || echo '(no migrations directory yet — run generate first)'"
 echo
 log "First 200 lines of generated SQL:"
 docker exec -w "$APP_WORKDIR" "$XYNE_APP_CONTAINER" sh -c \
   "cat migrations/*.sql 2>/dev/null | head -200 || echo '(no .sql files)'"
}


cmd_apply() {
 local OPTIND=1
 while getopts ":a:" opt; do
   case "$opt" in
     a) XYNE_APP_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$XYNE_APP_CONTAINER"
 log "Running 'bun run migrate' inside $XYNE_APP_CONTAINER (cwd=$APP_WORKDIR)..."
 docker exec -w "$APP_WORKDIR" "$XYNE_APP_CONTAINER" bun run migrate
 log "Done. Check status with: $0 status"
}


cmd_status() {
 local OPTIND=1
 while getopts ":c:" opt; do
   case "$opt" in
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$POSTGRES_CONTAINER"
 log "Applied migrations (from drizzle.__drizzle_migrations):"
 docker exec "$POSTGRES_CONTAINER" sh -c \
   "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"
      SELECT id, hash, to_timestamp(created_at/1000) AS applied_at
      FROM drizzle.__drizzle_migrations
      ORDER BY created_at;\"" \
   || die "could not read drizzle.__drizzle_migrations — has migrate ever run?"
}


cmd_reset() {
 local OPTIND=1
 while getopts ":a:" opt; do
   case "$opt" in
     a) XYNE_APP_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$XYNE_APP_CONTAINER"
 log "Removing first-boot marker $INIT_MARKER from $XYNE_APP_CONTAINER..."
 docker exec "$XYNE_APP_CONTAINER" sh -c "rm -f '$INIT_MARKER' && echo removed"
 log "Marker cleared. Next \`docker restart $XYNE_APP_CONTAINER\` will run generate+migrate."
 log "NOTE: this script did NOT restart the container — do that yourself when ready."
}


cmd_all() {
 local OPTIND=1
 local outdir=""
 while getopts ":o:a:c:" opt; do
   case "$opt" in
     o) outdir="$OPTARG" ;;
     a) XYNE_APP_CONTAINER="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$outdir" ]] || die "usage: all -o <backup_dir> [-a <app_container>] [-c <db_container>]"


 log "STEP 1/4 — Postgres safety backup"
 cmd_backup -o "$outdir" -c "$POSTGRES_CONTAINER"


 log "STEP 2/4 — generate migration files"
 cmd_generate -a "$XYNE_APP_CONTAINER"


 log "STEP 3/4 — inspect what will be applied"
 cmd_inspect -a "$XYNE_APP_CONTAINER"


 echo
 read -r -p "Proceed with \`bun run migrate\` on $XYNE_APP_CONTAINER? [y/N] " confirm
 case "$confirm" in
   y|Y|yes|YES) ;;
   *) log "Aborted before apply. Re-run \`$0 apply\` when ready."; exit 0 ;;
 esac


 log "STEP 4/4 — apply migrations"
 cmd_apply -a "$XYNE_APP_CONTAINER"


 log "All done. Verify with \`$0 status\`."
}


main() {
 local sub="${1:-}"
 shift || true
 case "$sub" in
   backup)   cmd_backup "$@" ;;
   generate) cmd_generate "$@" ;;
   inspect)  cmd_inspect "$@" ;;
   apply)    cmd_apply "$@" ;;
   status)   cmd_status "$@" ;;
   reset)    cmd_reset "$@" ;;
   all)      cmd_all "$@" ;;
   *) cat <<EOF >&2
Usage: $0 <backup|generate|inspect|apply|status|reset|all> [flags]


 backup    -o <dir>                 Postgres safety snapshot (delegates to migrate-psql.sh)
 generate  [-a <app_container>]     Run \`bun run generate\` inside xyne-app
 inspect   [-a <app_container>]     ls migrations/ and head -200 the SQL
 apply     [-a <app_container>]     Run \`bun run migrate\` inside xyne-app
 status    [-c <db_container>]      Print drizzle.__drizzle_migrations journal
 reset     [-a <app_container>]     Delete .xyne_initialized marker (no auto-restart)
 all       -o <dir> [-a ...] [-c ...]
                                     backup → generate → inspect → confirm → apply


Env defaults: XYNE_APP_CONTAINER=xyne-app, POSTGRES_CONTAINER=xyne-db,
             APP_WORKDIR=/usr/src/app/server,
             INIT_MARKER=/usr/src/app/server/storage/.xyne_initialized


See docs/MIGRATION.md → "Schema migrations on an existing DEST".
EOF
      exit 1 ;;
 esac
}


main "$@"



