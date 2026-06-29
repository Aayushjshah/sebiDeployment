#!/usr/bin/env bash
# migrate-kb.sh — Knowledge-base file migration helper.
# Moves the disk-side bytes of `kb_files/` from source to dest VM.
#
# Modes:
#   tar                On SOURCE VM. Tars the `kb_files/` directory (uses pigz when present).
#   gcloud-tar         On LAPTOP.    SSHes to a GCP VM via IAP, tars kb_files/ on the
#                                    remote (stages a .tar.gz file there), scps it back.
#                                    Requires free disk on the remote = ~size of compressed tar.
#   gcloud-stream-tar  On LAPTOP.    Same idea, but streams the tar over SSH directly into
#                                    a file on your laptop. ZERO remote disk overhead — use
#                                    this when /home or /tmp on the source VM is tight.
#   restore            On DEST VM.   Untars into the dest's kb_files location, fixes ownership.
#
# Usage:
#   ./migrate-kb.sh tar               -d /path/to/host/app-uploads  -o /path/to/output_dir
#   ./migrate-kb.sh gcloud-tar        [-i instance] [-z zone] [-p project] [-u ssh_user]
#                                     [-o local_dir] [-r remote_dir] [-d remote_data_dir]
#                                     [-S "sudo"|""]
#   ./migrate-kb.sh gcloud-stream-tar [-i instance] [-z zone] [-p project] [-u ssh_user]
#                                     [-o local_dir] [-d remote_data_dir] [-S "sudo"|""]
#   ./migrate-kb.sh restore           -t /path/to/kb_files.tar.gz   -d /path/to/host/app-uploads  -u <owner_user:group>
#
# Pain points this script handles (see docs/MIGRATION.md):
#   1. The tar must be created with `kb_files/` as the archive root, NOT the parent path —
#      otherwise restore lands in a nested dir and xyne can't find files.
#   2. Ownership must match the user that the xyne-app container reads as. On RHEL hosts
#      this is often a non-default user like spiuser3; on Ubuntu often `ubuntu`. Pass -u.
#   3. The script keeps the existing `kb_files/` aside as `kb_files.old.<date>` so you can
#      roll back without losing the original.
#   4. NEVER deletes data on its own — only renames.


set -euo pipefail


# gcloud-tar defaults (override with flags at call site)
GCLOUD_INSTANCE_DEFAULT="xyne-k8s-test"
GCLOUD_ZONE_DEFAULT="asia-southeast1-a"
GCLOUD_PROJECT_DEFAULT="xyne-spaces-sbx"
GCLOUD_USER_DEFAULT="sourish_mukherjee_juspay_in"
GCLOUD_LOCAL_OUTDIR_DEFAULT="${HOME}/Downloads"
GCLOUD_REMOTE_DATADIR_DEFAULT="/home/shivral_somani_juspay_in/xyne-stack/data/app-uploads"


die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }


cmd_tar() {
 local data_dir="" outdir=""
 while getopts ":d:o:" opt; do
   case "$opt" in
     d) data_dir="$OPTARG" ;;
     o) outdir="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$data_dir" && -n "$outdir" ]] \
   || die "usage: tar -d <host_app_uploads_dir> -o <output_dir>"
 [[ -d "$data_dir/kb_files" ]] || die "kb_files not found at $data_dir/kb_files"
 mkdir -p "$outdir"


 local stamp; stamp="$(date +%F-%H%M)"
 local out="$outdir/kb_files-${stamp}.tar.gz"


 log "Sizing kb_files..."
 du -sh "$data_dir/kb_files"


 log "Tarring kb_files → $out (using pigz if available)..."
 cd "$data_dir"
 if command -v pigz >/dev/null; then
   tar -I pigz -cf "$out" kb_files/
 else
   tar czf "$out" kb_files/
 fi


 ls -lh "$out"
 log "Done. Ship $out to the dest VM."
}


cmd_restore() {
 local tarball="" data_dir="" owner=""
 while getopts ":t:d:u:" opt; do
   case "$opt" in
     t) tarball="$OPTARG" ;;
     d) data_dir="$OPTARG" ;;
     u) owner="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done
 [[ -n "$tarball" && -n "$data_dir" && -n "$owner" ]] \
   || die "usage: restore -t <kb_files.tar.gz> -d <host_app_uploads_dir> -u <user:group>"
 [[ -f "$tarball" ]] || die "tarball not found: $tarball"
 [[ -d "$data_dir" ]] || die "dest app-uploads dir not found: $data_dir"


 if [[ -d "$data_dir/kb_files" ]]; then
   local backup="$data_dir/kb_files.old.$(date +%F-%H%M)"
   log "Moving existing kb_files aside → $backup"
   mv "$data_dir/kb_files" "$backup"
 fi


 log "Extracting tarball into $data_dir..."
 cd "$data_dir"
 if command -v pigz >/dev/null; then
   tar -I pigz -xf "$tarball"
 else
   tar xzf "$tarball"
 fi


 [[ -d "$data_dir/kb_files" ]] || die "extract didn't produce kb_files/ — inspect the tar"


 log "Setting ownership to $owner..."
 chown -R "$owner" "$data_dir/kb_files"


 log "Verify:"
 ls -la "$data_dir/kb_files" | head
 du -sh "$data_dir/kb_files"
 log "Done. The existing kb_files.old.* backup is preserved; delete after verifying."
}


cmd_gcloud_tar() {
 local instance="$GCLOUD_INSTANCE_DEFAULT"
 local zone="$GCLOUD_ZONE_DEFAULT"
 local project="$GCLOUD_PROJECT_DEFAULT"
 local gcloud_user="$GCLOUD_USER_DEFAULT"
 local local_outdir="$GCLOUD_LOCAL_OUTDIR_DEFAULT"
 local remote_data_dir="$GCLOUD_REMOTE_DATADIR_DEFAULT"
 local remote_outdir=""
 local remote_sudo="${REMOTE_SUDO-sudo}"


 while getopts ":i:z:p:u:o:r:d:S:" opt; do
   case "$opt" in
     i) instance="$OPTARG" ;;
     z) zone="$OPTARG" ;;
     p) project="$OPTARG" ;;
     u) gcloud_user="$OPTARG" ;;
     o) local_outdir="$OPTARG" ;;
     r) remote_outdir="$OPTARG" ;;
     d) remote_data_dir="$OPTARG" ;;
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
 local tar_name="kb_files-${stamp}.tar.gz"
 local tar_remote="${remote_outdir}/${tar_name}"


 log "gcloud target: ssh ${target} (zone=$zone project=$project, IAP)"
 log "Remote data dir: $remote_data_dir (expecting kb_files/ inside)"
 log "Remote tar dir : $remote_outdir   |   Local download dir: $local_outdir"
 log "Remote sudo    : '${remote_sudo:-<none>}' (override with -S, '-S \"\"' to disable)"


 log "Sanity-check: can we reach $target via IAP?"
 gcloud compute ssh "$target" "${gflags[@]}" --command="echo ok" >/dev/null \
   || die "could not ssh to $target — check gcloud auth, project access, IAP grant"


 log "Sanity-check: '$remote_data_dir/kb_files' exists on remote?"
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo test -d '$remote_data_dir/kb_files' || { echo MISSING; exit 1; }" \
   || die "kb_files not found at $remote_data_dir/kb_files on $instance (override with -d, or check 'docker inspect xyne-app' for the mount path)"


 log "Ensuring remote dir exists..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="mkdir -p '$remote_outdir'"


 log "Sizing kb_files on remote..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo du -sh '$remote_data_dir/kb_files'"


 log "Tarring kb_files on remote → $tar_remote (this can take a while if KB is large)..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="cd '$remote_data_dir' && if command -v pigz >/dev/null; then $remote_sudo tar -I pigz -cf '$tar_remote' kb_files/; else $remote_sudo tar czf '$tar_remote' kb_files/; fi && $remote_sudo chown \"\$(id -u):\$(id -g)\" '$tar_remote' && ls -lh '$tar_remote'"


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
 local remote_sudo="${REMOTE_SUDO-sudo}"


 while getopts ":i:z:p:u:o:d:S:" opt; do
   case "$opt" in
     i) instance="$OPTARG" ;;
     z) zone="$OPTARG" ;;
     p) project="$OPTARG" ;;
     u) gcloud_user="$OPTARG" ;;
     o) local_outdir="$OPTARG" ;;
     d) remote_data_dir="$OPTARG" ;;
     S) remote_sudo="$OPTARG" ;;
     \?) die "unknown flag -$OPTARG" ;;
   esac
 done


 command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH"
 mkdir -p "$local_outdir"


 local target="${gcloud_user}@${instance}"
 local gflags=(--zone="$zone" --project="$project" --tunnel-through-iap)
 local stamp; stamp="$(date +%F-%H%M)"
 local tar_name="kb_files-${stamp}.tar.gz"
 local tar_local="${local_outdir}/${tar_name}"
 local tar_partial="${tar_local}.partial"


 log "gcloud target  : ssh ${target} (zone=$zone project=$project, IAP)"
 log "Remote data dir: $remote_data_dir (expecting kb_files/ inside)"
 log "Streaming to   : $tar_local (zero remote disk overhead)"
 log "Remote sudo    : '${remote_sudo:-<none>}' (override with -S, '-S \"\"' to disable)"


 log "Sanity-check: can we reach $target via IAP?"
 gcloud compute ssh "$target" "${gflags[@]}" --command="echo ok" >/dev/null \
   || die "could not ssh to $target — check gcloud auth, project access, IAP grant"


 log "Sanity-check: '$remote_data_dir/kb_files' exists on remote?"
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo test -d '$remote_data_dir/kb_files' || { echo MISSING; exit 1; }" \
   || die "kb_files not found at $remote_data_dir/kb_files on $instance (override with -d, or check 'docker inspect xyne-app' for the mount path)"


 log "Sizing kb_files on remote (informational)..."
 gcloud compute ssh "$target" "${gflags[@]}" \
   --command="$remote_sudo du -sh '$remote_data_dir/kb_files'" || true


 log "Local free space check: $local_outdir"
 df -h "$local_outdir" | tail -1 || true


 # If pv is available locally, splice it into the pipeline for live progress.
 # Pass the remote's raw size as -s so pv can show a progress bar + ETA.
 # (Compressed transfer will hit 100% slightly early; that's expected.)
 local pv_pipe="cat"
 if command -v pv >/dev/null 2>&1; then
   local raw_bytes
   raw_bytes="$(gcloud compute ssh "$target" "${gflags[@]}" \
     --command="$remote_sudo du -sb '$remote_data_dir/kb_files' 2>/dev/null | awk '{print \$1}'" \
     2>/dev/null | tr -d '[:space:]' || true)"
   if [[ "$raw_bytes" =~ ^[0-9]+$ ]]; then
     log "pv progress: target ≈ $raw_bytes bytes raw (compressed will hit 100% slightly early)"
     pv_pipe="pv -s $raw_bytes -N kb_files"
   else
     log "pv progress: no -s hint (could not read remote raw size; ETA unavailable)"
     pv_pipe="pv -N kb_files"
   fi
 else
   log "pv not installed locally — pipeline will run without progress display."
   log "  Install with: brew install pv"
 fi


 log "Streaming kb_files tar over IAP → $tar_partial (this can take a while)..."
 # Tar streams to remote stdout → gcloud SSH streams it back over IAP → local
 # (optionally through pv) → redirects to .partial file. No remote intermediate file.
 # On success we mv .partial → final name so a half-written stream is obviously incomplete.
 if ! gcloud compute ssh "$target" "${gflags[@]}" \
      --command="cd '$remote_data_dir' && if command -v pigz >/dev/null; then $remote_sudo tar -I pigz -cf - kb_files/; else $remote_sudo tar czf - kb_files/; fi" \
      | $pv_pipe > "$tar_partial"; then
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
   *) cat <<EOF >&2
Usage: $0 <tar|gcloud-tar|gcloud-stream-tar|restore> [flags]


 tar               -d <host_app_uploads_dir> -o <output_dir>
                                      SOURCE: produce kb_files-<stamp>.tar.gz
 gcloud-tar        [-i instance] [-z zone] [-p project] [-u ssh_user]
                   [-o local_dir] [-r remote_dir] [-d remote_data_dir] [-S sudo_cmd]
                                      LAPTOP: ssh into a GCP VM via IAP, tar kb_files/
                                      on the remote, scp the .tar.gz back to your laptop.
                                      Stages a .tar.gz on the remote first.
 gcloud-stream-tar [-i instance] [-z zone] [-p project] [-u ssh_user]
                   [-o local_dir] [-d remote_data_dir] [-S sudo_cmd]
                                      LAPTOP: same as gcloud-tar but streams the tar
                                      over SSH directly into a file on your laptop.
                                      ZERO remote disk overhead — use when /home or
                                      /tmp on source is tight.
                                      Defaults (both gcloud-* modes):
                                        instance        = $GCLOUD_INSTANCE_DEFAULT
                                        zone            = $GCLOUD_ZONE_DEFAULT
                                        project         = $GCLOUD_PROJECT_DEFAULT
                                        ssh_user        = $GCLOUD_USER_DEFAULT
                                        local_dir       = $GCLOUD_LOCAL_OUTDIR_DEFAULT
                                        remote_data_dir = $GCLOUD_REMOTE_DATADIR_DEFAULT (expects kb_files/ inside)
                                        sudo_cmd        = "sudo" (use -S "" to disable)
                                      gcloud-tar only:
                                        remote_dir      = /home/<ssh_user>/xyne-migration
 restore           -t <tar.gz> -d <host_app_uploads_dir> -u <user:group>
                                      DEST:   safety-rename existing, extract, chown


See docs/MIGRATION.md.
EOF
      exit 1 ;;
 esac
}


main "$@"



