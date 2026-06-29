#!/usr/bin/env bash
# migrate-vespa.sh — Vespa index data migration helper.
#
# Modes:
#   tar                On SOURCE VM. Tars vespa-data LIVE (Vespa is NOT stopped).
#   gcloud-tar         On LAPTOP.    SSHes to a GCP VM via IAP, tars vespa-data LIVE on the
#                                    remote into a staged .tar.gz, then scps it back. Vespa
#                                    is not stopped at any point. Needs remote disk space.
#   gcloud-stream-tar  On LAPTOP.    Same as gcloud-tar but streams the tar over SSH directly
#                                    into a file on your laptop. Zero remote disk overhead.
#                                    Live tar — Vespa stays running.
#
# Live tar trade-off: Vespa keeps serving traffic during the snapshot. In practice most of
# vespa-data is immutable Lucene-style segments; the worst case is a few mid-write files
# captured in an inconsistent state, which Vespa typically recovers from on restore boot.
# `--ignore-failed-read` is passed to tar so a file vanishing between stat and open (e.g.
# a Vespa compaction) doesn't kill the whole stream.
#   restore            On DEST VM.   Stops Vespa, replaces vespa-data, sets uid 1000 ownership, starts.
#   remap              On DEST VM.   Bulk-updates kb_items identity field `createdBy` to a new email.
#                                    Required so search isn't filtered out for the new dest user.
#   verify             On either VM. Probes Vespa health, lists a sample doc, checks namespace.
#
# Usage:
#   ./migrate-vespa.sh tar               -d /path/to/host/data  -o /path/to/output_dir  [-c vespa]
#   ./migrate-vespa.sh gcloud-tar        [-i instance] [-z zone] [-p project] [-u ssh_user]
#                                        [-o local_dir] [-r remote_dir] [-d remote_data_dir]
#                                        [-c vespa_container] [-S "sudo"|""]
#   ./migrate-vespa.sh gcloud-stream-tar [-i instance] [-z zone] [-p project] [-u ssh_user]
#                                        [-o local_dir] [-d remote_data_dir]
#                                        [-c vespa_container] [-S "sudo"|""]
#   ./migrate-vespa.sh restore           -t /path/to/vespa-data.tar.gz  -d /path/to/host/data  [-c vespa]
#   ./migrate-vespa.sh remap             -e officer1@xyne.local  [-c vespa]  [-n namespace]  [-l cluster]
#   ./migrate-vespa.sh verify            [-c vespa]
#
# Pain points this script handles (see docs/MIGRATION.md → Vespa migration):
#   1. Container UID is 1000 — bind-mounted vespa-data MUST be chown'd to 1000:1000 or
#      Vespa fails with "mkdir var/tmp: permission denied" and restart-loops forever.
#   2. Two Vespa containers in one image: feed on :8080, query on :8081. /search/... is
#      only bound on 8081; /document/v1/... is on 8080. Common 404 source.
#   3. The namespace in doc IDs is the literal string "namespace" (NOT the cluster name
#      "my_content"). Visiting /document/v1/my_content/... returns 0 docs — the right
#      URL is /document/v1/namespace/<schema>/...
#   4. After restoring source's Vespa data, all kb_items docs still have `createdBy` set
#      to source user emails. xyne's query path filters by the logged-in user's email,
#      so search returns 0 hits until you bulk-update createdBy. The `remap` mode does
#      this in a single visit-update HTTP call.
#   5. clId / clFd in kb_items are UUIDs that match Postgres — DO NOT remap these.
#   6. We snapshot vespa-data LIVE (Vespa stays running). Cleanest snapshot would stop
#      Vespa first, but the operator explicitly chose live capture to avoid downtime.
#      `--ignore-failed-read` makes tar resilient to files Vespa removes mid-walk.


set -euo pipefail


VESPA_CONTAINER="${VESPA_CONTAINER:-vespa}"
VESPA_NAMESPACE="${VESPA_NAMESPACE:-namespace}"
VESPA_CLUSTER="${VESPA_CLUSTER:-my_content}"


# gcloud-tar defaults (override with flags at call site)
GCLOUD_INSTANCE_DEFAULT="xyne-k8s-test"
GCLOUD_ZONE_DEFAULT="asia-southeast1-a"
GCLOUD_PROJECT_DEFAULT="xyne-spaces-sbx"
GCLOUD_USER_DEFAULT="sourish_mukherjee_juspay_in"
GCLOUD_LOCAL_OUTDIR_DEFAULT="${HOME}/Downloads"
GCLOUD_REMOTE_DATADIR_DEFAULT="/home/shivral_somani_juspay_in/xyne-stack/data"


die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }


require_docker_container() {
 docker inspect "$1" >/dev/null 2>&1 || die "container '$1' not found"
}


cmd_tar() {
 local data_dir="" outdir=""
 while getopts ":d:o:c:" opt; do
   case "$opt" in
     d) data_dir="$OPTARG" ;;
     o) outdir="$OPTARG" ;;
     c) VESPA_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$data_dir" && -n "$outdir" ]] || die "usage: tar -d <host_data_dir> -o <output_dir>"
 [[ -d "$data_dir/vespa-data" ]] || die "vespa-data not found at $data_dir/vespa-data"
 mkdir -p "$outdir"


 local stamp; stamp="$(date +%F-%H%M)"
 local out="$outdir/vespa-data-${stamp}.tar.gz"


 log "Tarring vespa-data LIVE → $out (Vespa is NOT stopped)..."
 # Live tar — see file header for rationale. --ignore-failed-read tolerates files that
 # vanish between stat and open during an active Vespa run. Exit code 1 ("some files
 # differ" — file changed mid-read) is non-fatal; archive is still valid.
 cd "$data_dir"
 set +e
 if command -v pigz >/dev/null; then
   tar --ignore-failed-read -I pigz -cf "$out" vespa-data/
 else
   tar --ignore-failed-read -czf "$out" vespa-data/
 fi
 local rc=$?
 set -e
 [[ "$rc" -gt 1 ]] && die "tar exited $rc (fatal)"


 ls -lh "$out"
 log "Done. Ship $out to the dest VM."
}


cmd_restore() {
 local tarball="" data_dir=""
 while getopts ":t:d:c:" opt; do
   case "$opt" in
     t) tarball="$OPTARG" ;;
     d) data_dir="$OPTARG" ;;
     c) VESPA_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$tarball" && -n "$data_dir" ]] \
   || die "usage: restore -t <vespa-data.tar.gz> -d <host_data_dir>"
 [[ -f "$tarball" ]] || die "tarball not found: $tarball"
 [[ -d "$data_dir" ]] || die "dest data dir not found: $data_dir"
 require_docker_container "$VESPA_CONTAINER"


 log "Stopping Vespa and disabling auto-restart while we shuffle data..."
 docker stop "$VESPA_CONTAINER" >/dev/null 2>&1 || true
 docker update --restart=no "$VESPA_CONTAINER" >/dev/null


 if [[ -d "$data_dir/vespa-data" ]]; then
   local backup="$data_dir/vespa-data.old.$(date +%F-%H%M)"
   log "Moving existing vespa-data aside → $backup"
   mv "$data_dir/vespa-data" "$backup"
 fi


 log "Extracting tarball into $data_dir..."
 cd "$data_dir"
 if command -v pigz >/dev/null; then
   tar -I pigz -xf "$tarball"
 else
   tar xzf "$tarball"
 fi
 [[ -d "$data_dir/vespa-data" ]] || die "extract did not produce vespa-data/ — check tar root"


 log "Setting ownership to uid 1000 (Vespa runs as user 'vespa'=1000 inside the container)..."
 chown -R 1000:1000 "$data_dir/vespa-data"


 log "Re-enabling auto-restart and starting Vespa (proton may take 2-5 min to load)..."
 docker update --restart=unless-stopped "$VESPA_CONTAINER" >/dev/null
 docker start "$VESPA_CONTAINER" >/dev/null


 sleep 20
 log "Recent logs:"
 docker logs --tail 40 "$VESPA_CONTAINER" || true
 log "Done. Next: run \`$0 remap -e <new_email>\` to fix createdBy in kb_items docs."
}


cmd_remap() {
 local new_email=""
 while getopts ":e:c:n:l:" opt; do
   case "$opt" in
     e) new_email="$OPTARG" ;;
     c) VESPA_CONTAINER="$OPTARG" ;;
     n) VESPA_NAMESPACE="$OPTARG" ;;
     l) VESPA_CLUSTER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$new_email" ]] \
   || die "usage: remap -e <new_email> [-c <container>] [-n <namespace>] [-l <cluster>]"
 require_docker_container "$VESPA_CONTAINER"


 log "Bulk-updating createdBy on every kb_items doc to '$new_email'..."
 docker exec "$VESPA_CONTAINER" curl -sS -X PUT \
   "http://localhost:8080/document/v1/${VESPA_NAMESPACE}/kb_items/docid?selection=true&cluster=${VESPA_CLUSTER}" \
   -H "Content-Type: application/json" \
   -d "{\"fields\":{\"createdBy\":{\"assign\":\"${new_email}\"}}}"
 echo ""


 log "Verify (sample 2 docs):"
 docker exec "$VESPA_CONTAINER" curl -sS --max-time 15 \
   "http://localhost:8080/document/v1/?cluster=${VESPA_CLUSTER}&wantedDocumentCount=2" \
   | grep -o '"createdBy":"[^"]*"' | head -4 || true


 log "Done. Restart xyne-app so it clears any cached Vespa state."
}


cmd_verify() {
 while getopts ":c:" opt; do
   case "$opt" in
     c) VESPA_CONTAINER="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 require_docker_container "$VESPA_CONTAINER"


 log "Health probes:"
 for port in 19071 8080 8081; do
   echo -n "  port $port: "
   docker exec "$VESPA_CONTAINER" curl -sS --max-time 5 \
     "http://localhost:${port}/state/v1/health" 2>/dev/null \
     | head -c 200 || echo "(no response)"
   echo ""
 done


 log "Sample kb_items doc (using cluster=$VESPA_CLUSTER, ignoring namespace):"
 docker exec "$VESPA_CONTAINER" curl -sS --max-time 15 \
   "http://localhost:8080/document/v1/?cluster=${VESPA_CLUSTER}&wantedDocumentCount=1" \
   | head -50


 log "Detected namespace from sample doc ID:"
 docker exec "$VESPA_CONTAINER" curl -sS --max-time 15 \
   "http://localhost:8080/document/v1/?cluster=${VESPA_CLUSTER}&wantedDocumentCount=1" \
   | grep -o '"id":"id:[^:]*:[^:]*' | head -1 || true
}


cmd_gcloud_tar() {
 local instance="$GCLOUD_INSTANCE_DEFAULT"
 local zone="$GCLOUD_ZONE_DEFAULT"
 local project="$GCLOUD_PROJECT_DEFAULT"
 local gcloud_user="$GCLOUD_USER_DEFAULT"
 local local_outdir="$GCLOUD_LOCAL_OUTDIR_DEFAULT"
 local remote_data_dir="$GCLOUD_REMOTE_DATADIR_DEFAULT"
 local remote_outdir=""
 local remote_vespa_container="$VESPA_CONTAINER"
 local remote_sudo="${REMOTE_SUDO-sudo}"


 while getopts ":i:z:p:u:o:r:d:c:S:" opt; do
   case "$opt" in
     i) instance="$OPTARG" ;;
     z) zone="$OPTARG" ;;
     p) project="$OPTARG" ;;
     u) gcloud_user="$OPTARG" ;;
     o) local_outdir="$OPTARG" ;;
     r) remote_outdir="$OPTARG" ;;
     d) remote_data_dir="$OPTARG" ;;
     c) remote_vespa_container="$OPTARG" ;;
     S) remote_sudo="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done


 [[ -z "$remote_outdir" ]] && remote_outdir="/home/${gcloud_user}/xyne-migration"


 command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH"
 mkdir -p "$local_outdir"


 local target="${gcloud_user}@${instance}"
 local gflags=(--zone="$zone" --project="$project" --tunnel-through-iap)
 local stamp; stamp="$(date +%F-%H%M)"
 local tar_name="vespa-data-${stamp}.tar.gz"
 local tar_remote="${remote_outdir}/${tar_name}"


 log "gcloud target  : ssh ${target} (zone=$zone project=$project, IAP)"
 log "Remote data dir: $remote_data_dir (expecting vespa-data/ inside)"
 log "Vespa container: $remote_vespa_container (stays RUNNING — live tar, no stop/restart)"
 log "Remote tar dir : $remote_outdir   |   Local download dir: $local_outdir"
 log "Remote sudo    : '${remote_sudo:-<none>}' (override with -S, '-S \"\"' to disable)"


 log "Sanity-check: can we reach $target via IAP?"
 gcloud compute ssh "$target" "${gflags[@]}" --command="echo ok" >/dev/null \
   || die "could not ssh to $target — check gcloud auth, project access, IAP grant"


 log "Sanity-check: '$remote_data_dir/vespa-data' exists on remote?"
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo test -d '$remote_data_dir/vespa-data' || { echo MISSING; exit 1; }" \
   || die "vespa-data not found at $remote_data_dir/vespa-data on $instance (override with -d)"


 log "Ensuring remote dir exists..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="mkdir -p '$remote_outdir'"


 log "Tarring vespa-data LIVE on remote → $tar_remote (Vespa is NOT stopped)..."
 # Live tar — see gcloud-stream-tar comment. Exit code 1 from tar ("some files differ"
 # because a live Vespa write touched a file mid-archive) is treated as success.
 gcloud compute ssh "$target" "${gflags[@]}" --command="
cd '$remote_data_dir'
if command -v pigz >/dev/null; then
 $remote_sudo tar --ignore-failed-read -I pigz -cf '$tar_remote' vespa-data/
else
 $remote_sudo tar --ignore-failed-read -czf '$tar_remote' vespa-data/
fi
rc=\$?
if [ \$rc -gt 1 ]; then exit \$rc; fi
$remote_sudo chown \"\$(id -u):\$(id -g)\" '$tar_remote'
ls -lh '$tar_remote'
"


 log "Copying ${tar_name} → $local_outdir/ ..."
 gcloud compute scp "${gflags[@]}" "${target}:${tar_remote}" "$local_outdir/"


 log "Done. Local file:"
 ls -lh "$local_outdir/${tar_name}" 2>/dev/null || true
 log "Tip: the remote copy in $remote_outdir is left in place; '$remote_sudo rm' it on the VM when done."
}


cmd_gcloud_stream_tar() {
 local instance="$GCLOUD_INSTANCE_DEFAULT"
 local zone="$GCLOUD_ZONE_DEFAULT"
 local project="$GCLOUD_PROJECT_DEFAULT"
 local gcloud_user="$GCLOUD_USER_DEFAULT"
 local local_outdir="$GCLOUD_LOCAL_OUTDIR_DEFAULT"
 local remote_data_dir="$GCLOUD_REMOTE_DATADIR_DEFAULT"
 local remote_vespa_container="$VESPA_CONTAINER"
 local remote_sudo="${REMOTE_SUDO-sudo}"


 while getopts ":i:z:p:u:o:d:c:S:" opt; do
   case "$opt" in
     i) instance="$OPTARG" ;;
     z) zone="$OPTARG" ;;
     p) project="$OPTARG" ;;
     u) gcloud_user="$OPTARG" ;;
     o) local_outdir="$OPTARG" ;;
     d) remote_data_dir="$OPTARG" ;;
     c) remote_vespa_container="$OPTARG" ;;
     S) remote_sudo="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done


 command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH"
 mkdir -p "$local_outdir"


 local target="${gcloud_user}@${instance}"
 local gflags=(--zone="$zone" --project="$project" --tunnel-through-iap)
 local stamp; stamp="$(date +%F-%H%M)"
 local tar_name="vespa-data-${stamp}.tar.gz"
 local tar_local="${local_outdir}/${tar_name}"
 local tar_partial="${tar_local}.partial"


 log "gcloud target  : ssh ${target} (zone=$zone project=$project, IAP)"
 log "Remote data dir: $remote_data_dir (expecting vespa-data/ inside)"
 log "Vespa container: $remote_vespa_container (stays RUNNING — live tar, no stop/restart)"
 log "Streaming to   : $tar_local (zero remote disk overhead)"
 log "Remote sudo    : '${remote_sudo:-<none>}' (override with -S, '-S \"\"' to disable)"


 log "Sanity-check: can we reach $target via IAP?"
 gcloud compute ssh "$target" "${gflags[@]}" --command="echo ok" >/dev/null \
   || die "could not ssh to $target — check gcloud auth, project access, IAP grant"


 log "Sanity-check: '$remote_data_dir/vespa-data' exists on remote?"
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo test -d '$remote_data_dir/vespa-data' || { echo MISSING; exit 1; }" \
   || die "vespa-data not found at $remote_data_dir/vespa-data on $instance (override with -d)"


 log "Local free space check: $local_outdir"
 df -h "$local_outdir" | tail -1 || true


 # If pv is available locally, splice it into the pipeline for live progress.
 # Pass the remote raw size of vespa-data as -s so pv can show a progress bar + ETA.
 local pv_pipe="cat"
 if command -v pv >/dev/null 2>&1; then
   local raw_bytes
   raw_bytes="$(gcloud compute ssh "$target" "${gflags[@]}" \
     --command="$remote_sudo du -sb '$remote_data_dir/vespa-data' 2>/dev/null | awk '{print \$1}'" \
     2>/dev/null | tr -d '[:space:]' || true)"
   if [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
     log "pv progress: target ≈ $raw_bytes bytes raw (compressed will hit 100% slightly early)"
     pv_pipe="pv -s $raw_bytes -N vespa-data"
   else
     log "pv progress: no -s hint (could not read remote raw size; ETA unavailable)"
     pv_pipe="pv -N vespa-data"
   fi
 else
   log "pv not installed locally — pipeline will run without progress display."
   log "  Install with: brew install pv"
 fi


 log "Streaming vespa-data tar LIVE over IAP — Vespa is NOT stopped at any point..."
 # Live tar: Vespa keeps serving traffic. Tar may pick up files mid-write; in practice most
 # of vespa-data is immutable segments and any minor inconsistency is recovered on restore boot.
 # `--ignore-failed-read` lets tar continue past a file that vanished between stat and open.
 # GNU tar exit codes: 0 = success, 1 = "some files differ" (file changed/shrank during read —
 # the archive is still produced and valid), 2 = fatal. We treat exit 1 as success so a live
 # Vespa write mid-stream doesn't kill the whole capture.
 if ! gcloud compute ssh "$target" "${gflags[@]}" --command="
cd '$remote_data_dir'
if command -v pigz >/dev/null; then
 $remote_sudo tar --ignore-failed-read -I pigz -cf - vespa-data/
else
 $remote_sudo tar --ignore-failed-read -czf - vespa-data/
fi
rc=\$?
if [ \$rc -le 1 ]; then exit 0; else exit \$rc; fi
" | $pv_pipe > "$tar_partial"; then
   log "Stream failed. Partial file left at $tar_partial — inspect or rm and retry."
   die "tar stream failed"
 fi


 mv "$tar_partial" "$tar_local"


 log "Done. Local file:"
 ls -lh "$tar_local"


 log "Quick integrity check (tar -tzf | head -3)..."
 if tar -tzf "$tar_local" 2>/dev/null | head -3; then
   log "tar listing OK — archive appears valid."
 else
   log "WARNING: tar -tzf could not list the archive. It may be truncated; consider re-running."
 fi
}


main() {
 local sub="${1:-}"
 shift || true
 case "$sub" in
   tar)                cmd_tar "$@" ;;
   gcloud-tar)         cmd_gcloud_tar "$@" ;;
   gcloud-stream-tar)  cmd_gcloud_stream_tar "$@" ;;
   restore)            cmd_restore "$@" ;;
   remap)              cmd_remap "$@" ;;
   verify)             cmd_verify "$@" ;;
   *) cat <<EOF >&2
Usage: $0 <tar|gcloud-tar|gcloud-stream-tar|restore|remap|verify> [flags]


 tar               -d <host_data_dir> -o <output_dir>
                                      SOURCE: tar vespa-data LIVE (vespa stays running)
 gcloud-tar        [-i instance] [-z zone] [-p project] [-u ssh_user]
                   [-o local_dir] [-r remote_dir] [-d remote_data_dir]
                   [-c vespa_container] [-S sudo_cmd]
                                      LAPTOP: tar vespa-data LIVE on the remote, scp back.
                                      Vespa stays running throughout.
 gcloud-stream-tar [-i instance] [-z zone] [-p project] [-u ssh_user]
                   [-o local_dir] [-d remote_data_dir]
                   [-c vespa_container] [-S sudo_cmd]
                                      LAPTOP: stream tar over SSH directly into a file on
                                      your laptop. Zero remote disk overhead.
                                      Vespa stays running throughout.
                                      Defaults (both gcloud-* modes):
                                        instance        = $GCLOUD_INSTANCE_DEFAULT
                                        zone            = $GCLOUD_ZONE_DEFAULT
                                        project         = $GCLOUD_PROJECT_DEFAULT
                                        ssh_user        = $GCLOUD_USER_DEFAULT
                                        local_dir       = $GCLOUD_LOCAL_OUTDIR_DEFAULT
                                        remote_data_dir = $GCLOUD_REMOTE_DATADIR_DEFAULT (expects vespa-data/ inside)
                                        vespa_container = $VESPA_CONTAINER
                                        sudo_cmd        = "sudo" (use -S "" to disable)
                                      gcloud-tar only:
                                        remote_dir      = /home/<ssh_user>/xyne-migration
 restore           -t <vespa-data.tar.gz> -d <host_data_dir>
                                      DEST:   safety-rename existing, extract, chown 1000:1000, restart
 remap             -e <new_email>
                                      DEST:   bulk-update kb_items.createdBy via visit-update API
 verify
                                      Probes ports 19071/8080/8081, samples a doc, detects namespace


Env: VESPA_CONTAINER=vespa, VESPA_NAMESPACE=namespace, VESPA_CLUSTER=my_content
See docs/MIGRATION.md.
EOF
      exit 1 ;;
 esac
}


main "$@"



