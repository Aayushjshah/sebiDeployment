#!/usr/bin/env bash
# migrate-psql.sh — Postgres migration helper for xyne (both `xyne` and `keycloak` DBs).
#
# Modes:
#   dump         On SOURCE VM.  Produces dump file(s) for the xyne (and optionally keycloak) DB.
#   gcloud-dump  On LAPTOP.     SSHes to a GCP VM via IAP, runs pg_dump there, scps the
#                               dump file back to your laptop (default ~/Downloads).
#   backup       On DEST VM.    Backs up the dest's current DBs (safety net before restore).
#   restore      On DEST VM.    Drops + recreates dest DBs, then restores from source's dumps.
#   merge        On DEST VM.    Keeps dest users + workspaces; imports KB tables
#                               (collections, collection_items, collection_ls_projections)
#                               with owner remapped to a target user + workspace.
#                               Pass -A to ALSO import 'agents' + 'sub_agents' (skips
#                               agent_documents and user_agent_permissions on purpose).
#   fix-agents   On DEST VM.    Rewrites agent app_integrations.itemIds to current collection UUIDs.
#
# Usage:
#   ./migrate-psql.sh dump        -o /path/to/output_dir   [-c xyne-db]
#   ./migrate-psql.sh gcloud-dump [-i instance] [-z zone] [-p project] [-u ssh_user]
#                                 [-o local_dir] [-r remote_dir] [-c container]
#                                 [-S "sudo"|"" ] [-k]
#   ./migrate-psql.sh backup      -o /path/to/output_dir   [-c xyne-db]
#   ./migrate-psql.sh restore     -i /path/to/dump_dir     [-c xyne-db]
#   ./migrate-psql.sh merge       -s /path/to/source.dump  -u <dest_user_id> -w <dest_workspace_id> [-A] [-c xyne-db]
#   ./migrate-psql.sh fix-agents  [-a <agent_id>]          [-c xyne-db]
#
# Env defaults (override at the CLI):
#   POSTGRES_CONTAINER=xyne-db
#   ASSUME_YES=0       Set to 1 to skip the interactive destructive-mode confirmation.
#                       (Only meant for automation; never set this on the SOURCE VM.)
#
# Safety: restore / merge / fix-agents are destructive. They prompt for the postgres
# container name as a confirmation gate. If you typed the command on the SOURCE VM by
# accident, you can abort there before any DROP / TRUNCATE / UPDATE runs.
#
# Pain points this script handles (see docs/MIGRATION.md → Issues & Solutions):
#   1. `pg_dump -d xyne` silently misses Keycloak — we dump xyne AND keycloak.
#   2. Drop-then-restore is safer than --clean --if-exists when dest has incompatible drift.
#   3. The (owner_id, name) unique partial index on collections fires when consolidating
#      multiple source owners into one dest owner — we drop the index, run UPDATE, then
#      rename duplicates with " (N)" suffix before the final import.
#   4. Vespa-related fields (vespa_doc_id) are preserved verbatim so the kb_items in
#      Vespa stay reachable from Postgres after the merge.


set -euo pipefail


POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-xyne-db}"
ASSUME_YES="${ASSUME_YES:-0}"


# gcloud-dump defaults (override with flags at call site)
GCLOUD_INSTANCE_DEFAULT="xyne-k8s-test"
GCLOUD_ZONE_DEFAULT="asia-southeast1-a"
GCLOUD_PROJECT_DEFAULT="xyne-spaces-sbx"
GCLOUD_USER_DEFAULT="sourish_mukherjee_juspay_in"
GCLOUD_LOCAL_OUTDIR_DEFAULT="${HOME}/Downloads"
GCLOUD_REMOTE_CONTAINER_DEFAULT="xyne-db"


die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }


require_docker_container() {
 local name="$1"
 docker inspect "$name" >/dev/null 2>&1 || die "container '$name' not found (is the stack up?)"
}


# Interactive gate for destructive modes. Asks the operator to type the postgres
# container name back, so a typo'd run on the SOURCE VM doesn't silently DROP/TRUNCATE.
# Skip with ASSUME_YES=1 in automation contexts.
confirm_destructive() {
 local mode="$1"
 if [[ "$ASSUME_YES" -eq 1 ]]; then
   log "ASSUME_YES=1 set — skipping destructive-mode confirmation for '$mode'"
   return 0
 fi
 local host; host="$(hostname 2>/dev/null || echo unknown)"
 cat >&2 <<EOF


 WARNING: '$mode' is DESTRUCTIVE and is intended for the DEST VM ONLY.
          Target postgres container : $POSTGRES_CONTAINER
          Local hostname            : $host


 If you launched this on the SOURCE VM by mistake, abort NOW (Ctrl-C).


 To proceed, type the postgres container name ('$POSTGRES_CONTAINER'):
EOF
 local confirm
 read -r confirm
 if [[ "$confirm" != "$POSTGRES_CONTAINER" ]]; then
   die "Aborted: confirmation did not match '$POSTGRES_CONTAINER'."
 fi
 log "Confirmation accepted. Proceeding with '$mode'."
}


# Read POSTGRES_USER and POSTGRES_DB from the container's env (no need to pass creds)
read_creds() {
 PG_USER="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ^POSTGRES_USER= | cut -d= -f2)"
 PG_DB="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ^POSTGRES_DB= | cut -d= -f2)"
 [[ -n "$PG_USER" && -n "$PG_DB" ]] || die "could not read POSTGRES_USER / POSTGRES_DB from container env"
 log "Using user='$PG_USER', xyne_db='$PG_DB' on container '$POSTGRES_CONTAINER'"
}


cmd_dump() {
 local outdir="" include_keycloak=0
 while getopts ":o:c:k" opt; do
   case "$opt" in
     o) outdir="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     k) include_keycloak=1 ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$outdir" ]] || die "usage: dump -o <output_dir> [-k] [-c <container>]"
 mkdir -p "$outdir"
 require_docker_container "$POSTGRES_CONTAINER"
 read_creds


 local stamp; stamp="$(date +%F-%H%M)"
 local xyne_out="$outdir/xyne-postgres-${stamp}.dump"


 log "Dumping '$PG_DB' DB → $xyne_out"
 docker exec "$POSTGRES_CONTAINER" sh -c \
   "pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Fc -Z 6 --no-owner --no-acl" \
   > "$xyne_out"


 if [[ "$include_keycloak" -eq 1 ]]; then
   local kc_out="$outdir/keycloak-postgres-${stamp}.dump"
   log "Dumping 'keycloak' DB → $kc_out (only because -k was passed)"
   docker exec "$POSTGRES_CONTAINER" sh -c \
     "pg_dump -U \"\$POSTGRES_USER\" -d keycloak -Fc -Z 6 --no-owner --no-acl" \
     > "$kc_out"
   ls -lh "$xyne_out" "$kc_out"
 else
   log "Skipping keycloak dump (the recommended flow keeps dest's keycloak as-is)."
   log "Pass -k if you really want to migrate keycloak (e.g., brand-new dest VM)."
   ls -lh "$xyne_out"
 fi


 log "Done. Ship the dump(s) to the dest VM."
}


cmd_backup() {
 local outdir=""
 while getopts ":o:c:" opt; do
   case "$opt" in
     o) outdir="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$outdir" ]] || die "usage: backup -o <output_dir> [-c <container>]"
 mkdir -p "$outdir"
 require_docker_container "$POSTGRES_CONTAINER"
 read_creds


 local stamp; stamp="$(date +%F-%H%M)"
 local xyne_out="$outdir/dest-xyne-backup-${stamp}.dump"
 local kc_out="$outdir/dest-keycloak-backup-${stamp}.dump"


 log "Backing up dest '$PG_DB' DB → $xyne_out"
 docker exec "$POSTGRES_CONTAINER" sh -c \
   "pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Fc -Z 6 --no-owner --no-acl" \
   > "$xyne_out"


 # Always back up keycloak on dest — we don't touch it in the recommended flow,
 # but a snapshot lets you roll back if anything goes sideways.
 log "Backing up dest 'keycloak' DB → $kc_out"
 docker exec "$POSTGRES_CONTAINER" sh -c \
   "pg_dump -U \"\$POSTGRES_USER\" -d keycloak -Fc -Z 6 --no-owner --no-acl" \
   > "$kc_out"


 ls -lh "$xyne_out" "$kc_out"
 log "Safety backup complete. Keep these files until the restore is verified."
}


cmd_restore() {
 local indir="" with_keycloak=0
 while getopts ":i:c:k" opt; do
   case "$opt" in
     i) indir="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     k) with_keycloak=1 ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$indir" ]] || die "usage: restore -i <dump_dir> [-k] [-c <container>]"
 require_docker_container "$POSTGRES_CONTAINER"
 read_creds
 confirm_destructive "restore"


 local xyne_dump kc_dump
 xyne_dump="$(ls -1t "$indir"/xyne-postgres-*.dump 2>/dev/null | head -1 || true)"
 kc_dump="$(ls -1t "$indir"/keycloak-postgres-*.dump 2>/dev/null | head -1 || true)"


 log "Stopping xyne-app + sync workers (they hold DB connections)..."
 docker ps --format '{{.Names}}' | grep -E 'xyne-app|sync' | xargs -r docker stop || true


 [[ -n "$xyne_dump" ]] || die "no xyne dump found in $indir"
 log "Restoring xyne DB from $xyne_dump"
 cat "$xyne_dump" | docker exec -i "$POSTGRES_CONTAINER" sh -c \
   "dropdb -U \"\$POSTGRES_USER\" --if-exists \"\$POSTGRES_DB\" && \
    createdb -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\" && \
    pg_restore -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" --no-owner --no-acl"


 if [[ "$with_keycloak" -eq 1 ]]; then
   [[ -n "$kc_dump" ]] || die "no keycloak dump found in $indir (and -k was passed)"
   log "Stopping Keycloak before restoring its DB..."
   docker stop xyne-keycloak >/dev/null 2>&1 || true
   log "Restoring keycloak DB from $kc_dump"
   cat "$kc_dump" | docker exec -i "$POSTGRES_CONTAINER" sh -c \
     "dropdb -U \"\$POSTGRES_USER\" --if-exists keycloak && \
      createdb -U \"\$POSTGRES_USER\" keycloak && \
      pg_restore -U \"\$POSTGRES_USER\" -d keycloak --no-owner --no-acl"
   docker start xyne-keycloak >/dev/null
   log "WARNING: post-restore you must update Keycloak admin → realm xyne-shared →"
   log "   Clients → xyne-web → Valid redirect URIs (to point at dest VM's URL)"
   log "   and verify the client secret matches xyne-app's KEYCLOAK_* env."
 else
   log "Skipping keycloak (the recommended flow keeps dest's keycloak untouched)."
   log "Pass -k to also restore keycloak from the source dump."
 fi


 log "Starting xyne-app + sync workers..."
 docker start xyne-app >/dev/null 2>&1 || true
 for c in $(docker ps -aq --filter status=exited --filter name=sync); do
   docker start "$c" >/dev/null 2>&1 || true
 done


 log "Quick sanity:"
 docker exec "$POSTGRES_CONTAINER" sh -c \
   "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"
    SELECT 'collections' t, count(*) FROM collections
    UNION ALL SELECT 'collection_items', count(*) FROM collection_items
    UNION ALL SELECT 'users', count(*) FROM users
    UNION ALL SELECT 'workspaces', count(*) FROM workspaces;\""
}


cmd_merge() {
 local src_dump="" dest_user_id="" dest_ws_id="" include_agents=0
 while getopts ":s:u:w:c:A" opt; do
   case "$opt" in
     s) src_dump="$OPTARG" ;;
     u) dest_user_id="$OPTARG" ;;
     w) dest_ws_id="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     A) include_agents=1 ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$src_dump" && -n "$dest_user_id" && -n "$dest_ws_id" ]] \
   || die "usage: merge -s <source_xyne_dump> -u <dest_user_id> -w <dest_workspace_id> [-A] [-c <container>]"
 [[ "$dest_user_id" =~ ^[0-9]+$ ]] || die "dest_user_id must be an integer"
 [[ "$dest_ws_id"   =~ ^[0-9]+$ ]] || die "dest_workspace_id must be an integer"
 [[ -f "$src_dump" ]] || die "source dump not found: $src_dump"
 require_docker_container "$POSTGRES_CONTAINER"
 read_creds
 confirm_destructive "merge"
 [[ "$include_agents" -eq 1 ]] && log "Agents migration enabled (-A): will also TRUNCATE+import 'agents' and 'sub_agents'."


 log "Stopping xyne-app + sync workers..."
 docker ps --format '{{.Names}}' | grep -E 'xyne-app|sync' | xargs -r docker stop || true


 log "Loading source dump into temp DB 'xyne_source'..."
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d postgres \
   -c "DROP DATABASE IF EXISTS xyne_source;" >/dev/null
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d postgres \
   -c "CREATE DATABASE xyne_source;" >/dev/null


 # pg_restore may emit non-fatal errors when SOURCE's dump contains extensions
 # the DEST postgres doesn't have (e.g. SOURCE on postgis/postgis image, DEST on
 # plain postgres → CREATE EXTENSION postgis fails, tiger/topology schemas missing).
 # Those errors are about PostGIS artifacts, NOT xyne application tables.
 # We tolerate a non-zero exit IF the xyne tables we need actually made it in.
 set +e
 cat "$src_dump" | docker exec -i "$POSTGRES_CONTAINER" sh -c \
   "pg_restore -U \"\$POSTGRES_USER\" -d xyne_source --no-owner --no-acl" >/dev/null
 local restore_rc=$?
 set -e


 log "Verifying required tables landed in xyne_source..."
 local required_list="'collections','collection_items','collection_ls_projections'"
 local expected=3
 if [[ "$include_agents" -eq 1 ]]; then
   required_list="$required_list,'agents','sub_agents'"
   expected=5
 fi
 local got
 got=$(docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d xyne_source -tA -c \
   "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ($required_list);" \
   | tr -d '[:space:]')


 if [[ "$got" -lt "$expected" ]]; then
   die "pg_restore left xyne_source incomplete: only $got of $expected required xyne tables present. Inspect pg_restore output above — this is a real failure (schema mismatch or corrupt dump), not just PostGIS noise."
 fi


 if [[ "$restore_rc" -ne 0 ]]; then
   log "pg_restore exited $restore_rc but all $expected xyne tables made it through."
   log "  The errors above are non-fatal (e.g. PostGIS extension on SOURCE that DEST doesn't have)."
   log "  Continuing — only xyne app tables matter for the merge."
 fi


 log "Remapping owner_id/workspace_id in temp DB to dest values..."
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d xyne_source -v ON_ERROR_STOP=1 -c "
   DROP INDEX IF EXISTS unique_owner_collection_name_not_deleted;


   ALTER TABLE collections DROP CONSTRAINT IF EXISTS collections_owner_id_users_id_fk;
   ALTER TABLE collections DROP CONSTRAINT IF EXISTS collections_last_updated_by_id_users_id_fk;
   ALTER TABLE collections DROP CONSTRAINT IF EXISTS collections_workspace_id_workspaces_id_fk;
   ALTER TABLE collection_items DROP CONSTRAINT IF EXISTS collection_items_owner_id_users_id_fk;
   ALTER TABLE collection_items DROP CONSTRAINT IF EXISTS collection_items_uploaded_by_id_users_id_fk;
   ALTER TABLE collection_items DROP CONSTRAINT IF EXISTS collection_items_last_updated_by_id_users_id_fk;
   ALTER TABLE collection_items DROP CONSTRAINT IF EXISTS collection_items_workspace_id_workspaces_id_fk;


   UPDATE collections
   SET owner_id=$dest_user_id, last_updated_by_id=$dest_user_id, workspace_id=$dest_ws_id;


   UPDATE collection_items
   SET owner_id=$dest_user_id, uploaded_by_id=$dest_user_id, last_updated_by_id=$dest_user_id,
       workspace_id=$dest_ws_id;


   WITH ranked AS (
     SELECT id, name, ROW_NUMBER() OVER (PARTITION BY name ORDER BY created_at) AS rn
     FROM collections WHERE deleted_at IS NULL
   )
   UPDATE collections c SET name = c.name || ' (' || r.rn || ')'
   FROM ranked r WHERE c.id = r.id AND r.rn > 1;
 " >/dev/null


 if [[ "$include_agents" -eq 1 ]]; then
   log "Remapping agents/sub_agents in temp DB..."
   # See docs/MIGRATION.md → 'Agents migration' for why we (1) drop the partial unique
   # index on default agents before consolidating to one workspace, then (2) keep only
   # the oldest is_default=true per workspace.
   docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d xyne_source -v ON_ERROR_STOP=1 -c "
     DROP INDEX IF EXISTS agents_default_per_workspace_unique;


     ALTER TABLE agents     DROP CONSTRAINT IF EXISTS agents_user_id_users_id_fk;
     ALTER TABLE agents     DROP CONSTRAINT IF EXISTS agents_workspace_id_workspaces_id_fk;
     ALTER TABLE sub_agents DROP CONSTRAINT IF EXISTS sub_agents_workspace_id_workspaces_id_fk;


     UPDATE agents     SET user_id      = $dest_user_id, workspace_id = $dest_ws_id;
     UPDATE sub_agents SET workspace_id = $dest_ws_id;


     WITH ranked AS (
       SELECT id, ROW_NUMBER() OVER (PARTITION BY workspace_id ORDER BY created_at) AS rn
       FROM agents WHERE is_default = true
     )
     UPDATE agents SET is_default = false
     WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
   " >/dev/null
 fi


 log "Truncating dest's KB tables..."
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
   -c "TRUNCATE collection_ls_projections, collection_items, collections RESTART IDENTITY CASCADE;" >/dev/null


 if [[ "$include_agents" -eq 1 ]]; then
   log "Truncating dest's agent tables (CASCADE clears sub_agents, agent_documents, user_agent_permissions)..."
   docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
     -c "TRUNCATE user_agent_permissions, agent_documents, sub_agents, agents RESTART IDENTITY CASCADE;" >/dev/null
 fi


 log "Dumping KB tables from xyne_source and loading into dest..."
 docker exec "$POSTGRES_CONTAINER" pg_dump -U "$PG_USER" -d xyne_source --data-only \
   --table=collections --table=collection_items --table=collection_ls_projections \
   | docker exec -i "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
       >/dev/null


 if [[ "$include_agents" -eq 1 ]]; then
   log "Dumping agents + sub_agents from xyne_source and loading into dest..."
   # agent_documents references chats/messages (not migrated) → skipped.
   # user_agent_permissions becomes meaningless when all rows collapse to one dest user → skipped.
   docker exec "$POSTGRES_CONTAINER" pg_dump -U "$PG_USER" -d xyne_source --data-only \
     --table=agents --table=sub_agents \
     | docker exec -i "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
         >/dev/null
 fi


 log "Dropping temp DB..."
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d postgres \
   -c "DROP DATABASE xyne_source;" >/dev/null


 log "Verifying counts:"
 if [[ "$include_agents" -eq 1 ]]; then
   docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "
     SELECT 'collections' t, count(*) FROM collections
     UNION ALL SELECT 'collection_items', count(*) FROM collection_items
     UNION ALL SELECT 'collection_ls_projections', count(*) FROM collection_ls_projections
     UNION ALL SELECT 'agents', count(*) FROM agents
     UNION ALL SELECT 'sub_agents', count(*) FROM sub_agents;"
 else
   docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "
     SELECT 'collections' t, count(*) FROM collections
     UNION ALL SELECT 'collection_items', count(*) FROM collection_items
     UNION ALL SELECT 'collection_ls_projections', count(*) FROM collection_ls_projections;"
 fi


 log "Starting xyne-app + sync workers..."
 docker start xyne-app >/dev/null 2>&1 || true
 for c in $(docker ps -aq --filter status=exited --filter name=sync); do
   docker start "$c" >/dev/null 2>&1 || true
 done


 if [[ "$include_agents" -eq 1 ]]; then
   log "Done. Imported agents already reference SOURCE collection UUIDs (preserved by merge), so"
   log "fix-agents is OPTIONAL but recommended as a safety pass: run \`$0 fix-agents\` to refresh"
   log "every agent's itemIds against the current collections table."
 else
   log "Done. NEXT: run \`$0 fix-agents\` to wire agents to the new collection UUIDs."
 fi
}


cmd_fix_agents() {
 local agent_id=""
 while getopts ":a:c:" opt; do
   case "$opt" in
     a) agent_id="$OPTARG" ;;
     c) POSTGRES_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 local where=""
 if [[ -n "$agent_id" ]]; then
   [[ "$agent_id" =~ ^[0-9]+$ ]] || die "agent_id must be an integer"
   where="WHERE id = $agent_id"
 fi
 require_docker_container "$POSTGRES_CONTAINER"
 read_creds
 confirm_destructive "fix-agents"


 log "Rewriting agent.app_integrations.itemIds to current collection UUIDs${agent_id:+ for agent id=$agent_id}..."
 docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "
   UPDATE agents
   SET app_integrations = jsonb_set(
     jsonb_set(COALESCE(app_integrations, '{}'::jsonb), '{knowledge_base,selectedAll}', 'false'::jsonb),
     '{knowledge_base,itemIds}',
     (SELECT COALESCE(jsonb_agg('cl-' || id::text), '[]'::jsonb)
        FROM collections WHERE deleted_at IS NULL)
   )
   $where;


   SELECT id, name, jsonb_pretty(app_integrations->'knowledge_base') AS kb
   FROM agents $where;
 "
}


cmd_gcloud_dump() {
 local instance="$GCLOUD_INSTANCE_DEFAULT"
 local zone="$GCLOUD_ZONE_DEFAULT"
 local project="$GCLOUD_PROJECT_DEFAULT"
 local gcloud_user="$GCLOUD_USER_DEFAULT"
 local local_outdir="$GCLOUD_LOCAL_OUTDIR_DEFAULT"
 local remote_container="$GCLOUD_REMOTE_CONTAINER_DEFAULT"
 local remote_outdir=""
 # GCP VMs typically require sudo for docker. Override with -S "" if the
 # remote user is already in the docker group, or -S "doas" / similar.
 local remote_sudo="${REMOTE_SUDO-sudo}"
 local include_keycloak=0


 while getopts ":i:z:p:u:o:r:c:S:k" opt; do
   case "$opt" in
     i) instance="$OPTARG" ;;
     z) zone="$OPTARG" ;;
     p) project="$OPTARG" ;;
     u) gcloud_user="$OPTARG" ;;
     o) local_outdir="$OPTARG" ;;
     r) remote_outdir="$OPTARG" ;;
     c) remote_container="$OPTARG" ;;
     S) remote_sudo="$OPTARG" ;;
     k) include_keycloak=1 ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done


 # Default remote dir derives from the gcloud user's home so the path is
 # absolute (gcloud compute scp doesn't expand ~ before the SSH session).
 [[ -z "$remote_outdir" ]] && remote_outdir="/home/${gcloud_user}/xyne-migration"


 command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH"
 mkdir -p "$local_outdir"


 local target="${gcloud_user}@${instance}"
 local gflags=(--zone="$zone" --project="$project" --tunnel-through-iap)
 local stamp; stamp="$(date +%F-%H%M)"
 local xyne_name="xyne-postgres-${stamp}.dump"
 local xyne_remote="${remote_outdir}/${xyne_name}"


 log "gcloud target: ssh ${target} (zone=$zone project=$project, IAP)"
 log "Remote dump dir: $remote_outdir   |   Local download dir: $local_outdir"
 log "Remote docker prefix: '${remote_sudo:-<none>}' (override with -S, '-S \"\"' to disable)"


 log "Sanity-check: can we reach $target via IAP?"
 gcloud compute ssh "$target" "${gflags[@]}" --command="echo ok" >/dev/null \
   || die "could not ssh to $target — check gcloud auth, project access, IAP grant"


 log "Sanity-check: is container '$remote_container' running on the remote?"
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo docker inspect '$remote_container' >/dev/null 2>&1 || { echo MISSING; exit 1; }" \
   || die "container '$remote_container' not found on $instance (try -S '' if you don't need sudo, or check docker access)"


 log "Ensuring remote dir exists..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="mkdir -p '$remote_outdir'"


 log "Running pg_dump on remote → $xyne_remote ..."
 # Note: \$POSTGRES_USER / \$POSTGRES_DB are expanded by the shell inside the
 # docker container (NOT locally and NOT in the SSH wrapper shell).
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo docker exec '$remote_container' sh -c 'pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Fc -Z 6 --no-owner --no-acl' > '$xyne_remote' && ls -lh '$xyne_remote'"


 log "Copying ${xyne_name} → $local_outdir/ ..."
 gcloud compute scp "${gflags[@]}" "${target}:${xyne_remote}" "$local_outdir/"


 if [[ "$include_keycloak" -eq 1 ]]; then
   local kc_name="keycloak-postgres-${stamp}.dump"
   local kc_remote="${remote_outdir}/${kc_name}"
   log "Running pg_dump of 'keycloak' on remote → $kc_remote ..."
   gcloud compute ssh "$target" "${gflags[@]}" \
     --command="$remote_sudo docker exec '$remote_container' sh -c 'pg_dump -U \"\$POSTGRES_USER\" -d keycloak -Fc -Z 6 --no-owner --no-acl' > '$kc_remote' && ls -lh '$kc_remote'"
   log "Copying ${kc_name} → $local_outdir/ ..."
   gcloud compute scp "${gflags[@]}" "${target}:${kc_remote}" "$local_outdir/"
 else
   log "Skipping keycloak dump (pass -k to include it)."
 fi


 log "Done. Local files:"
 ls -lh "$local_outdir/${xyne_name}" 2>/dev/null || true
 if [[ "$include_keycloak" -eq 1 ]]; then
   ls -lh "$local_outdir/keycloak-postgres-${stamp}.dump" 2>/dev/null || true
 fi
 log "Tip: the remote copy in $remote_outdir is left in place; rm it on the VM when you're done."
}


main() {
 local sub="${1:-}"
 shift || true
 case "$sub" in
   dump)         cmd_dump "$@" ;;
   gcloud-dump)  cmd_gcloud_dump "$@" ;;
   backup)       cmd_backup "$@" ;;
   restore)      cmd_restore "$@" ;;
   merge)        cmd_merge "$@" ;;
   fix-agents)   cmd_fix_agents "$@" ;;
   *) cat <<EOF >&2
Usage: $0 <dump|gcloud-dump|backup|restore|merge|fix-agents> [flags]


 dump        -o <dir> [-k]                        SOURCE: dump xyne DB (add -k to also dump keycloak)
 gcloud-dump [-i instance] [-z zone] [-p project] [-u ssh_user]
             [-o local_dir] [-r remote_dir] [-c container] [-S sudo_cmd] [-k]
                                                  LAPTOP: ssh into a GCP VM via IAP, run pg_dump
                                                  on the remote xyne-db container, scp the .dump
                                                  file back to your laptop.
                                                  Defaults:
                                                    instance   = $GCLOUD_INSTANCE_DEFAULT
                                                    zone       = $GCLOUD_ZONE_DEFAULT
                                                    project    = $GCLOUD_PROJECT_DEFAULT
                                                    ssh_user   = $GCLOUD_USER_DEFAULT
                                                    local_dir  = $GCLOUD_LOCAL_OUTDIR_DEFAULT
                                                    remote_dir = /home/<ssh_user>/xyne-migration
                                                    container  = $GCLOUD_REMOTE_CONTAINER_DEFAULT
                                                    sudo_cmd   = "sudo"   (use -S "" to disable
                                                                 if the remote user is in the
                                                                 docker group; env: REMOTE_SUDO)
 backup      -o <dir>                             DEST:   pre-restore safety backup (both xyne + keycloak)
 restore     -i <dir> [-k]                        DEST:   drop+recreate xyne (add -k to also restore keycloak)
 merge       -s <xyne.dump> -u <uid> -w <wsid> [-A]
                                                  DEST:   keep dest users; import KB tables.
                                                  With -A: also import agents + sub_agents
                                                  (skips agent_documents, user_agent_permissions).
 fix-agents  [-a <agent_id>]                      DEST:   rewrite agent itemIds to current collections


Env: POSTGRES_CONTAINER (default: xyne-db). All Postgres-side commands accept -c <container>.
    ASSUME_YES=1 to skip the destructive-mode confirmation prompt (automation only;
    NEVER set this on the source VM).


NOTE: the recommended demo→customer migration NEVER touches keycloak on dest.
Use -k only for brand-new dest VMs where you want to start from source's auth state.


See docs/MIGRATION.md.
EOF
      exit 1 ;;
 esac
}


main "$@"




