#!/usr/bin/env bash
# =============================================================================
# store-applier-test.sh <scripts dir>: the stores' applier, the scripts
# store-paths.sh and store-journal.sh as the template renders them with
# StorePaths (components/seaweedfs/scripts), run as the CronJob's pod runs
# them, against a pretend SeaweedFS and Kubernetes API
# (scripts/testdata/store-applier: weed, grpcurl, curl and kubectl on a
# directory tree). make verify runs it.
# =============================================================================
# The owner's rule (infrared-docs-internal ADR 0087, Updates, 2026-11-17):
# nothing is deleted before its copy is verified at its new path. Each case
# checks a part of it, or of the operator's two contracts:
#
#   paths            each rule made exactly what is wanted (deleted, then
#                    written whole), a rule as it should be left alone, the
#                    rules written before deleted and no other, a deleted
#                    org's prefix purged, the filer's log pruned, and what was
#                    done in infrared-store-paths-applied
#   paths-refused    a purge of the platform's own files, a rule outside an
#                    org's kind, or a hash that does not match: nothing done
#   leader           the masters' calls follow the raft leader: /cluster/status,
#                    else each master by name; none answering fails the run
#   measure          each move's files, the free space, the repositories found
#   copy             copying recorded before the first copy; each file copied
#                    as new data with its source's time, a repository's own
#                    files alone; verified; no source file touched
#   delete           only verified moves; file by file; folders only if empty
#   mismatch         a destination file that differs is never written over,
#                    and the source stays
#   corrupt          a copy that does not match its source is not verified,
#                    and a delete asked of it deletes nothing
#   failed-copy      a copy that fails leaves the source
#   resume           a run stopped mid-copy is taken up again: what was copied
#                    is kept, the rest copied, then verified
#   timeout          every curl carries a connect timeout and a time limit
#                    that grows with the file; a copy or a read that stalls
#                    times out and fails its step like any failed call,
#                    nothing deleted, and the next run resumes, keeping a copy
#                    the gateway finished after the call gave up
#   changed          a delete whose copy changed after its verification
#                    deletes nothing
#   stale            a journal another migration took stops the run
#   tree             a template's snapshots copied into a shared folder, the
#                    others' files there left alone
#   precopy          while Zot serves: each blob copied, timed and verified,
#                    its manifest recorded; no other file copied; the delta;
#                    a later pass copies only new blobs, removes copies of
#                    blobs Zot deleted, retimes one pushed again, and reads no
#                    blob its manifest vouches for; a refused or bad copy, and
#                    a pass killed midway, taken up again
#   final            with Zot stopped: the destination made the source and
#                    verified, reading only what nothing vouches for; unmark
#                    deletes each verified source's oci-layout, mark copies it
#                    back
#   retire           with Zot at the new root: a source as verified deleted
#                    file by file, a blob Zot deleted since counted; a source
#                    or a copy changed since its verification deletes nothing
#   discard          a move turned back: this migration's copies removed, a
#                    file it did not copy left and named; refused while the
#                    source lacks its oci-layout
#   rollback         moving back, the repositories found are none of the old
#                    root's, and not SeaweedFS's own uploads
#   journal-keys     the sidecar writes the applier's keys alone
# =============================================================================
# shellcheck disable=SC2015 # a check's ok and FAIL, as verify.sh writes them
# shellcheck disable=SC2016 # the run's own PID, expanded in the shell it starts
set -euo pipefail
scripts="$(cd "${1:?usage: scripts/store-applier-test.sh <the rendered components/seaweedfs/scripts>}" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
fakes="$here/testdata/store-applier"
for t in jq sha256sum mkfifo; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

fail=0
ok() { echo "ok:   store applier: $*"; }
bad() { echo "FAIL: store applier: $*" >&2; fail=1; }
root="$(mktemp -d)"
trap 'find "$root" -depth -delete 2>/dev/null || true' EXIT

# --- The pretend stores -----------------------------------------------------------
S=""
# new_state <case>: an empty SeaweedFS of two volume servers, 100 GB each, 60
# and 50 GB free, and no ConfigMap.
new_state() {
  S="$root/$1"
  mkdir -p "$S/fs" "$S/mtime" "$S/cm" "$S/status" "$S/work"
  : >"$S/calls"
  echo '{"locations": []}' >"$S/conf.json"
  echo '{"topologyInfo": {"dataCenterInfos": [{"rackInfos": [{"dataNodeInfos": [{"id": "10.0.0.1:8080"}, {"id": "10.0.0.2:8080"}]}]}]}}' >"$S/volumes.json"
  echo '{"DiskStatuses": [{"dir": "/data", "all": 100000000000, "free": 60000000000}]}' >"$S/status/10.0.0.1:8080.json"
  echo '{"DiskStatuses": [{"dir": "/data", "all": 100000000000, "free": 50000000000}]}' >"$S/status/10.0.0.2:8080.json"
}
# put <filer path> <content> <mtime>
put() {
  mkdir -p "$(dirname "$S/fs$1")" "$(dirname "$S/mtime$1")"
  printf '%s' "$2" >"$S/fs$1"
  echo "$3" >"$S/mtime$1"
}
# unput <filer path>: a file gone, as a deletion leaves it.
unput() { rm "$S/fs$1" "$S/mtime$1"; }
# blob <repository folder> <content> <mtime>: a blob named by its digest.
blob() {
  local h
  h="$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
  put "$1/blobs/sha256/$h" "$2" "$3"
  echo "$h"
}
# cm <name> <data, JSON>
cm() { jq -n --arg n "$1" --argjson d "$2" '{metadata: {name: $n, resourceVersion: "1"}, data: $d}' >"$S/cm/$1.json"; }
# journal <id> <from> <to> <moves> <seq> <want> [scope]: the operator's keys,
# with the want's hash as the operator makes it; the applier's keys as they
# were.
journal() {
  local h old='{}'
  h="$(printf '%s\n%s\n%s' "$1" "$5" "$6" | sha256sum | cut -d' ' -f1)"
  if [ -f "$S/cm/infrared-store-moves.json" ]; then
    old="$(jq -c '.data | with_entries(select(.key == "measured" or .key == "outcome" or (.key | startswith("state."))))' "$S/cm/infrared-store-moves.json")"
  fi
  cm infrared-store-moves "$(jq -cn --arg id "$1" --arg from "$2" --arg to "$3" --arg moves "$4" --arg seq "$5" --arg want "$6" \
    --arg h "$h" --arg scope "${7:-}" --argjson old "$old" \
    '$old + {format: "1", id: $id, direction: "forward", from: $from, to: $to, moves: $moves, seq: $seq, want: $want, wantHash: $h,
      failures: "0", left: "", previous: "", pausedAt: ""} + (if $scope == "" then {} else {scope: $scope} end)')"
}
# run_applier [env...]: the pod: the sidecar journal in the background, the
# container weed in front, each with the fakes' settings given; the applier's
# exit code.
run_applier() {
  local rc=0 jpid
  find "$S/work" -mindepth 1 -delete
  env "$@" PATH="$fakes:$PATH" FAKE_STATE="$S" WORK="$S/work" NAMESPACE=stores bash "$scripts/store-journal.sh" >"$S/journal.log" 2>&1 &
  jpid=$!
  env "$@" PATH="$fakes:$PATH" FAKE_STATE="$S" WORK="$S/work" WEED="$fakes/weed" GRPCURL="$fakes/grpcurl" GRPC_TLS=false \
    S3_REGISTRY_ACCESS_KEY_ID=AKIDREGISTRY0000000000 S3_REGISTRY_SECRET_ACCESS_KEY=registrysecretkey \
    S3_ATE_SNAPSHOTS_ACCESS_KEY_ID=AKIDSNAPSHOTS00000000 S3_ATE_SNAPSHOTS_SECRET_ACCESS_KEY=snapshotssecretkey \
    BUCKET_COPIES=2 JOURNAL_WAIT=120 bash -c 'export FAKE_MAIN_PID=$$; exec bash "$0"' "$scripts/store-paths.sh" >"$S/applier.log" 2>&1 || rc=$?
  kill "$jpid" 2>/dev/null || true
  wait "$jpid" 2>/dev/null || true
  return "$rc"
}
# data <ConfigMap> <key>
data() { jq -r --arg k "$2" '.data[$k] // ""' "$S/cm/$1.json"; }
# steps <n>: move n's steps, in order.
steps() { data infrared-store-moves "state.$1" | awk 'NF { print $2 }' | tr '\n' ' ' | sed 's/ $//'; }
# last_step <n>: move n's last line.
last_step() { data infrared-store-moves "state.$1" | awk 'NF' | tail -n 1; }
# tree_of <filer folder>: every file below it, with its content's hash and its
# time: what must be the same before and after.
tree_of() {
  if [ ! -d "$S/fs$1" ]; then return 0; fi
  (cd "$S/fs$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" "$(cat "$S/mtime$1/${f#./}")"
  done)
}
show() { echo "--- $S/applier.log" >&2; tail -n 20 "$S/applier.log" >&2; echo "--- $S/journal.log" >&2; tail -n 5 "$S/journal.log" >&2; }

# The registry before the layout: acme/web with its own files (an upload left
# over among them) and acme/web/api, a repository nested in it.
registry_repos() {
  WEB=/buckets/registry/zot/zot/acme/web
  put "$WEB/index.json" '{"schemaVersion":2,"manifests":[]}' 1700000100
  put "$WEB/oci-layout" '{"imageLayoutVersion":"1.0.0"}' 1700000101
  B1="$(blob "$WEB" layer-one 1700000102)"
  B2="$(blob "$WEB" config-one 1700000103)"
  put "$WEB/.uploads/u1" partial 1700000104
  put "$WEB/api/index.json" '{"schemaVersion":2,"manifests":[1]}' 1700000200
  blob "$WEB/api" layer-api 1700000201 >/dev/null
  NEW=/buckets/registry/acme/images/web
  MOVES=$'1 acme/web/api acme/images/web/api images - empty\n2 acme/web acme/images/web images - empty\n'
}
FROM=/buckets/registry/zot/zot/
TO=/buckets/registry/

# --- The path rules ----------------------------------------------------------------
paths_cm() { # paths_cm <rules> <purge> <prune days> [hash]
  local h
  h="$(printf 'format=1\nrules:\n%spurge:\n%spruneLogDays=%s\n' "$1" "$2" "$3" | sha256sum | cut -d' ' -f1)"
  cm infrared-store-paths "$(jq -cn --arg r "$1" --arg p "$2" --arg d "$3" --arg h "${4:-$h}" '{format: "1", hash: $h, rules: $r, purge: $p, pruneLogDays: $d}')"
}
new_state paths
cat >"$S/conf.json" <<'EOF'
{"locations": [
  {"locationPrefix": "/buckets/registry/acme/images/", "replication": "000", "volumeGrowthCount": 1},
  {"locationPrefix": "/buckets/media/acme/summary-videos/", "ttl": "30d", "readOnly": true},
  {"locationPrefix": "/buckets/registry/gone/images/", "replication": "002", "volumeGrowthCount": 3},
  {"locationPrefix": "/buckets/notours/", "ttl": "7d"}
]}
EOF
rules=$'/buckets/media/acme/summary-videos/ -ttl=90d -volumeGrowthCount=1\n/buckets/registry/acme/images/ -replication=000 -volumeGrowthCount=1\n'
paths_cm "$rules" $'/buckets/media/globex/\n' 30
cm infrared-store-paths-applied '{"format": "1", "rules": "/buckets/media/acme/summary-videos/\n/buckets/registry/acme/images/\n/buckets/registry/gone/images/\n"}'
put /buckets/media/globex/summary-videos/runs/r1/video.mp4 video 1700000000
put /buckets/media/acme/pictures/owner face 1700000000
old_day="$(date -u -d "@$(($(date -u +%s) - 40 * 86400))" +%Y-%m-%d 2>/dev/null || date -u -r "$(($(date -u +%s) - 40 * 86400))" +%Y-%m-%d)"
new_day="$(date -u -d "@$(($(date -u +%s) - 10 * 86400))" +%Y-%m-%d 2>/dev/null || date -u -r "$(($(date -u +%s) - 10 * 86400))" +%Y-%m-%d)"
put "/topics/.system/log/$old_day/00-00.1" old 1700000000
put "/topics/.system/log/$new_day/00-00.1" new 1700000000
rc=0
run_applier || rc=$?
conf="$(jq -c -S '[.locations[] | {key: .locationPrefix, value: (del(.locationPrefix))}] | from_entries' "$S/conf.json")"
[ "$rc" = 0 ] \
  && [ "$(jq -c -S '.["/buckets/media/acme/summary-videos/"]' <<<"$conf")" = '{"ttl":"90d","volumeGrowthCount":1}' ] \
  && [ "$(jq -c -S '.["/buckets/registry/acme/images/"]' <<<"$conf")" = '{"replication":"000","volumeGrowthCount":1}' ] \
  && [ "$(jq -c '.["/buckets/registry/gone/images/"]' <<<"$conf")" = null ] \
  && [ "$(jq -c '.["/buckets/notours/"]' <<<"$conf")" = '{"ttl":"7d"}' ] \
  && [ "$(grep -c 'fs.configure -locationPrefix=/buckets/registry/acme/images/' "$S/calls")" = 0 ] \
  && grep -qx 'weed fs.configure -locationPrefix=/buckets/media/acme/summary-videos/ -delete -apply' "$S/calls" \
  && ok "paths: a rule changed by hand is deleted, then written whole (its read-only gone), one as wanted is left alone, the one written before and no longer wanted is deleted, and one not the applier's stays" \
  || { bad "paths: the filer's rules are $conf (exit $rc)"; show; }
[ ! -e "$S/fs/buckets/media/globex" ] && [ -f "$S/fs/buckets/media/acme/pictures/owner" ] \
  && [ ! -e "$S/fs/topics/.system/log/$old_day" ] && [ -f "$S/fs/topics/.system/log/$new_day/00-00.1" ] \
  && ok "paths: the deleted org's prefix is purged and no other org's, and the filer's log keeps its last 30 days" \
  || bad "paths: the purge or the log's prune is wrong"
[ "$(data infrared-store-paths-applied format)/$(data infrared-store-paths-applied result)" = 1/applied ] \
  && [ "$(data infrared-store-paths-applied hash)" = "$(data infrared-store-paths hash)" ] \
  && [ "$(data infrared-store-paths-applied rules)" = $'/buckets/media/acme/summary-videos/\n/buckets/registry/acme/images/' ] \
  && [ "$(data infrared-store-paths-applied purged)" = /buckets/media/globex/ ] \
  && [ -n "$(data infrared-store-paths-applied at)" ] && [ -n "$(data infrared-store-paths-applied message)" ] \
  && ok "paths: infrared-store-paths-applied says what was applied: the hash, the rules held, the prefix purged" \
  || bad "paths: infrared-store-paths-applied is $(jq -c .data "$S/cm/infrared-store-paths-applied.json")"

for refused in "platform-purge" "outside" "hash"; do
  new_state "paths-$refused"
  echo '{"locations": [{"locationPrefix": "/buckets/media/acme/pictures/", "ttl": "7d"}]}' >"$S/conf.json"
  put /buckets/media/platform/pictures/owner face 1700000000
  case "$refused" in
    platform-purge) paths_cm $'/buckets/media/acme/pictures/ -ttl=30d -volumeGrowthCount=1\n' $'/buckets/media/platform/\n' "" ;;
    outside) paths_cm $'/buckets/media/ -ttl=30d -volumeGrowthCount=1\n' "" "" ;;
    hash) paths_cm $'/buckets/media/acme/pictures/ -ttl=30d -volumeGrowthCount=1\n' "" "" 0000 ;;
  esac
  cm infrared-store-paths-applied '{}'
  rc=0
  run_applier || rc=$?
  [ "$rc" != 0 ] && [ "$(data infrared-store-paths-applied result)" = failed ] \
    && [ "$(jq -c '.locations' "$S/conf.json")" = '[{"locationPrefix":"/buckets/media/acme/pictures/","ttl":"7d"}]' ] \
    && [ -f "$S/fs/buckets/media/platform/pictures/owner" ] && ! grep -q '^weed fs.rm\|^weed fs.configure -' "$S/calls" \
    && ok "paths-refused ($refused): nothing applied, nothing removed, and the failure recorded: $(data infrared-store-paths-applied message)" \
    || { bad "paths-refused ($refused): exit $rc, $(jq -c .data "$S/cm/infrared-store-paths-applied.json")"; show; }
done

# --- The masters: only the raft leader answers a master's gRPC ----------------------
# MASTER_GRPC is a headless Service, every master's name (three of them off
# one node): a follower answers "raft.Server: Not current leader". The
# measure's VolumeList follows the leader /cluster/status names, else each
# master by its own name; with none answering, it fails, and nothing is done.
LEADER=seaweedfs-master-2.seaweedfs-master.stores:19333
PEERS="seaweedfs-master-0.seaweedfs-master.stores:19333 seaweedfs-master-1.seaweedfs-master.stores:19333 $LEADER"
STATUS='{"IsLeader":false,"Leader":"seaweedfs-master-2.seaweedfs-master.stores:9333.19333","Peers":["seaweedfs-master-0.seaweedfs-master.stores:9333.19333","seaweedfs-master-1.seaweedfs-master.stores:9333.19333"]}'
for how in status names none; do
  new_state "leader-$how"
  registry_repos
  journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 1 $'measure\n'
  rc=0
  case "$how" in
    status) run_applier FAKE_MASTER_LEADER="$LEADER" FAKE_CLUSTER_STATUS="$STATUS" || rc=$? ;;
    names) run_applier FAKE_MASTER_LEADER="$LEADER" FAKE_CLUSTER_STATUS_FAIL=true MASTER_GRPC_PEERS="$PEERS" || rc=$? ;;
    none) run_applier FAKE_MASTER_LEADER=seaweedfs-master-9.seaweedfs-master.stores:19333 FAKE_CLUSTER_STATUS_FAIL=true \
      MASTER_GRPC_PEERS="$PEERS" || rc=$? ;;
  esac
  m="$(data infrared-store-moves measured)"
  answered="$(grep '^master ' "$S/calls" | awk '{ print $2 }' | tr '\n' ' ')"
  case "$how" in
    status)
      [ "$rc" = 0 ] && grep -qx 'free 40000000000' <<<"$m" && [ "$answered" = "seaweedfs-master.stores:19333 $LEADER " ] \
        && ok "leader: a follower behind the masters' Service, then the leader /cluster/status names answers the measure's VolumeList" \
        || { bad "leader-status: exit $rc, asked $answered, measured $m"; show; } ;;
    names)
      [ "$rc" = 0 ] && grep -qx 'free 40000000000' <<<"$m" && [ "$answered" = "seaweedfs-master.stores:19333 $PEERS " ] \
        && ok "leader: with /cluster/status down, each master by its name until the leader answers" \
        || { bad "leader-names: exit $rc, asked $answered, measured $m"; show; } ;;
    none)
      [ "$rc" != 0 ] && [ -z "$m" ] && [[ "$(data infrared-store-moves outcome)" == *"Not current leader"* ]] \
        && ! grep -q '^s3 copy \|^removed ' "$S/calls" \
        && ok "leader: with no master answering, the run fails saying why, and nothing is measured, copied or removed" \
        || { bad "leader-none: exit $rc, outcome $(data infrared-store-moves outcome)"; show; } ;;
  esac
done

# --- The migration: measure, copy and verify, delete ------------------------------
new_state moves
registry_repos
before_web="$(tree_of /buckets/registry/zot/zot/acme)"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 1 $'measure\n'
rc=0
run_applier || rc=$?
m="$(data infrared-store-moves measured)"
want1="$(data infrared-store-moves wantHash)"
[ "$rc" = 0 ] && [ "$(sed -n 1p <<<"$m")" = "want $want1" ] && grep -qx 'free 40000000000' <<<"$m" \
  && grep -qE '^entry 1 2 [0-9]+ 0 0$' <<<"$m" && grep -qE '^entry 2 5 [0-9]+ 0 0$' <<<"$m" \
  && [ "$(grep '^found ' <<<"$m" | tr '\n' ' ')" = "found acme/web found acme/web/api " ] \
  && [ "$(data infrared-store-moves outcome | cut -d' ' -f1,3)" = "$want1 applied" ] \
  && ok "measure: each move's own files (5 for acme/web, its nested repository and uploads apart), the least free space less a tenth of the disk times the servers over the copies, and both repositories found" \
  || { bad "measure: $m / $(data infrared-store-moves outcome)"; show; }

journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 1\ncopy 2\n'
rc=0
run_applier || rc=$?
[ "$rc" = 0 ] && [ "$(steps 1)" = "copying copied verified" ] && [ "$(steps 2)" = "copying copied verified" ] \
  && [ "$(last_step 2 | cut -d' ' -f4)" = 5 ] \
  && [ "$(data infrared-store-moves state.2 | sed -n 2p | cut -d' ' -f2,4,5)" = "copied $(last_step 2 | cut -d' ' -f4,5)" ] \
  && ok "copy: copying, copied and verified recorded for each move, the copied files and bytes the verified ones" \
  || { bad "copy: state.1 '$(steps 1)', state.2 '$(steps 2)' (exit $rc)"; show; }
# The copies: every own file of the source, the same bytes and time, none of
# the nested repository's under acme/web's copy but its own.
[ "$(tree_of /buckets/registry/acme/images/web | grep -v '^./api/')" = "$(tree_of "$WEB" | grep -v '^./api/')" ] \
  && [ "$(tree_of /buckets/registry/acme/images/web/api)" = "$(tree_of "$WEB/api")" ] \
  && [ "$(tree_of /buckets/registry/zot/zot/acme)" = "$before_web" ] \
  && ! grep -q '^removed ' "$S/calls" && ! grep -q 'with other chunks' "$S/calls" \
  && [ "$(grep -c '^s3 copy ' "$S/calls")" = 7 ] \
  && ok "copy: each source file copied once, as new data, with its source's bytes and modification time; the source untouched, nothing removed, every time set with the entry's own chunks" \
  || { bad "copy: the copies are not the sources' files"; show; }

journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 3 $'delete 1\ndelete 2\nvacuum\nmeasure\n'
rc=0
run_applier || rc=$?
m="$(data infrared-store-moves measured)"
[ "$rc" = 0 ] && [ "$(last_step 1 | cut -d' ' -f2,4)" = "deleted 2" ] && [ "$(last_step 2 | cut -d' ' -f2,4)" = "deleted 5" ] \
  && [ ! -e "$S/fs$WEB" ] && [ -z "$(tree_of "$WEB")" ] \
  && [ "$(tree_of /buckets/registry/acme/images/web | grep -c .)" = 7 ] \
  && ! grep -E '^weed fs.rm (-r|-rf) ' "$S/calls" | grep -q . \
  && grep -qx 'weed volume.vacuum -collection=registry -garbageThreshold=0.1' "$S/calls" \
  && grep -qE '^entry 2 0 0 5 [0-9]+$' <<<"$m" && ! grep -q '^found ' <<<"$m" \
  && ok "delete: each verified move's own files removed one by one (never fs.rm -r), then its empty folders; the copies intact; the registry vacuumed and measured again" \
  || { bad "delete: state.1 '$(last_step 1)', state.2 '$(last_step 2)' (exit $rc)"; show; }

# --- A destination file that differs is never written over ---------------------------
new_state mismatch
registry_repos
before="$(tree_of "$WEB")"
put "$NEW/blobs/sha256/$B1" evil 1600000000
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\n'
rc=0
run_applier || rc=$?
[ "$rc" = 0 ] && [ "$(steps 2)" = "copying mismatch" ] && [ "$(cat "$S/fs$NEW/blobs/sha256/$B1")" = evil ] \
  && [ "$(cat "$S/mtime$NEW/blobs/sha256/$B1")" = 1600000000 ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ! grep -q "^s3 copy $WEB/blobs/sha256/$B1 " "$S/calls" \
  && ok "mismatch: a file at the destination that is not the source's is neither written over nor given a time, the move records mismatch, the source is untouched" \
  || { bad "mismatch: state.2 '$(steps 2)', the destination file $(cat "$S/fs$NEW/blobs/sha256/$B1")"; show; }

# --- A copy that does not match is not verified, and is not deleted ----------------------
new_state corrupt
registry_repos
before="$(tree_of "$WEB")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\n'
rc=0
run_applier FAKE_COPY_CORRUPT='*/acme/images/web/index.json' || rc=$?
first="$(steps 2)"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 3 $'delete 2\n'
run_applier || rc=$?
[ "$first" = "copying copied mismatch" ] && [ "$(last_step 2 | cut -d' ' -f2)" = failed ] \
  && [ "$(tree_of "$WEB")" = "$before" ] && ! grep -q "^removed $WEB" "$S/calls" \
  && ok "corrupt: a copy whose bytes differ from its source is recorded mismatch, never verified, and a delete asked of it records failed and deletes nothing" \
  || { bad "corrupt: state.2 '$first' then '$(last_step 2)'"; show; }

# --- A copy that fails leaves the source ---------------------------------------------
new_state failed-copy
registry_repos
before="$(tree_of "$WEB")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\n'
rc=0
run_applier FAKE_COPY_FAIL='*/acme/images/web/oci-layout' || rc=$?
[ "$(steps 2)" = "copying failed" ] && [ ! -e "$S/fs$NEW/oci-layout" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && [ "$(data infrared-store-moves outcome | cut -d' ' -f3)" = applied ] \
  && ok "failed-copy: a copy the gateway refuses records failed for the move, the source untouched, and the run goes on to its outcome" \
  || { bad "failed-copy: state.2 '$(steps 2)'"; show; }

# --- A run stopped mid-copy is taken up again ---------------------------------------------
new_state resume
registry_repos
before="$(tree_of "$WEB")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\n'
rc=0
run_applier FAKE_KILL_AFTER_COPIES=2 || rc=$?
stopped="$(steps 2)"
outcome="$(data infrared-store-moves outcome)"
copies_before="$(grep -c '^s3 copy ' "$S/calls")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 3 $'copy 2\n'
run_applier || true
[ "$rc" != 0 ] && [ "$stopped" = copying ] && [ -z "$outcome" ] && [ "$copies_before" = 2 ] \
  && [ "$(steps 2)" = "copying copying copied verified" ] && [ "$(grep -c '^s3 copy ' "$S/calls")" = 5 ] \
  && [ "$(tree_of "$NEW" | grep -v '^./api/')" = "$(tree_of "$WEB" | grep -v '^./api/')" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ok "resume: a run stopped after two copies records no outcome; the next keeps those two (the same bytes, given their time), copies the other three, and verifies" \
  || { bad "resume: stopped '$stopped' (exit $rc), then '$(steps 2)', $(grep -c '^s3 copy ' "$S/calls") copies"; show; }

# --- A call that stalls times out, fails its step, and the next run resumes ----------------------
# A blob of 3 MiB, whose calls get a minute and three seconds; the others a
# minute. Its copy stalls, though the gateway finishes it after the call gave
# up; then a read of a copy stalls; then nothing does.
new_state timeout
registry_repos
BIG="$(blob "$WEB" "$(head -c 3145728 /dev/zero | tr '\0' b)" 1700000105)"
before="$(tree_of "$WEB")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\ndelete 2\n'
run_applier FAKE_STALL="$NEW/blobs/sha256/$BIG" FAKE_STALL_LANDS=true || true
first="$(steps 2)"
why="$(data infrared-store-moves state.2 | sed -n 2p)"
copies_first="$(grep -c '^s3 copy ' "$S/calls" || true)"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 3 $'copy 2\n'
run_applier FAKE_STALL="$NEW/.uploads/u1" || true
second="$(steps 2)"
copies_second="$(grep -c '^s3 copy ' "$S/calls" || true)"
[ "$first" = "copying failed failed" ] && [[ "$why" == *"could not be copied"*"(28) Operation timed out"* ]] \
  && grep -qxF "s3 timed out PUT $NEW/blobs/sha256/$BIG after 63" "$S/calls" \
  && [ "$second" = "copying failed failed copying failed" ] && [ "$copies_second" = "$copies_first" ] \
  && grep -qxF "s3 timed out GET $NEW/.uploads/u1 after 60" "$S/calls" \
  && [ "$(tree_of "$WEB")" = "$before" ] && ! grep -q '^removed ' "$S/calls" \
  && ok "timeout: a copy that stalls past its limit (a minute, and a second a MiB) records failed and a delete asked after it deletes nothing; the next run's read that stalls records failed too and copies nothing more; the source untouched" \
  || { bad "timeout: '$first' ($why), then '$second'"; show; }
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 4 $'copy 2\n'
run_applier || true
[ "$(steps 2)" = "copying failed failed copying failed copying copied verified" ] \
  && [ "$(grep -c '^s3 copy ' "$S/calls")" = 6 ] && [ "$(grep -c "^s3 copy $WEB/blobs/sha256/$BIG " "$S/calls")" = 1 ] \
  && [ "$(tree_of "$NEW" | grep -v '^./api/')" = "$(tree_of "$WEB" | grep -v '^./api/')" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ! grep -q '^no time limit ' "$S/calls" \
  && ok "timeout: the next run resumes: the copy the gateway finished is kept, not written over, the rest copied once each, and verified; every call had its limits" \
  || { bad "timeout: the run after: '$(steps 2)', $(grep -c '^s3 copy ' "$S/calls") copies"; show; }

# --- A copy changed after its verification is not deleted ------------------------------------
new_state changed
registry_repos
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\n'
run_applier || true
verified="$(steps 2)"
before="$(tree_of "$WEB")"
rm "$S/fs$NEW/blobs/sha256/$B2"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 3 $'delete 2\n'
run_applier || true
[ "$verified" = "copying copied verified" ] && [ "$(last_step 2 | cut -d' ' -f2)" = failed ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ok "changed: a verified move whose copy lost a file since is not deleted: failed, the source untouched" \
  || { bad "changed: '$verified' then '$(last_step 2)'"; show; }

# --- A journal another migration took stops the run ---------------------------------------
new_state stale
registry_repos
before="$(tree_of "$WEB")"
journal 20261117T101500Z "$FROM" "$TO" "$MOVES" 2 $'copy 2\ndelete 2\n'
rc=0
run_applier FAKE_STALE_AFTER=1 || rc=$?
[ "$rc" != 0 ] && [ "$(steps 2)" = copying ] && [ -z "$(data infrared-store-moves outcome)" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ok "stale: once another migration holds the journal, the run records nothing more, writes no outcome and deletes nothing" \
  || { bad "stale: exit $rc, state.2 '$(steps 2)'"; show; }

# --- A template's snapshots, into a folder they share -----------------------------------------
new_state tree
SN=/buckets/ate-snapshots/platform
put "$SN/counter-v1/atespaces/platform/actors/a1/snapshots/s1/manifest.json" '{"a":1}' 1700000300
put "$SN/counter-v1/atespaces/platform/actors/a1/snapshots/s1/pages.img.zstd" pages 1700000301
put "$SN/counter-v1/atespaces/ate-golden/actors/t1/snapshots/g1/manifest.json" '{"g":1}' 1700000302
put "$SN/counter-v1/atespaces/platform/tags/tg1" tag 1700000303
put "$SN/sandbox-v1/atespaces/platform/actors/a2/snapshots/s2/manifest.json" '{"a":2}' 1700000304
put "$SN/snapshots/atespaces/ate-golden/actors/t9/snapshots/g9/manifest.json" '{"v2":9}' 1700000400
before_counter="$(tree_of "$SN/counter-v1")"
before_sandbox="$(tree_of "$SN/sandbox-v1")"
TMOVES=$'1 counter-v1/atespaces atespaces snapshots - empty\n2 sandbox-v1/atespaces atespaces snapshots - empty\n'
journal 20261117T120000Z "$SN/" "$SN/snapshots/" "$TMOVES" 1 $'copy 1\ncopy 2\nmeasure\n' tree
rc=0
run_applier || rc=$?
m="$(data infrared-store-moves measured)"
[ "$rc" = 0 ] && [ "$(steps 1)" = "copying copied verified" ] && [ "$(steps 2)" = "copying copied verified" ] \
  && [ "$(last_step 1 | cut -d' ' -f4)" = 4 ] && [ "$(last_step 2 | cut -d' ' -f4)" = 1 ] \
  && [ "$(tree_of "$SN/counter-v1")" = "$before_counter" ] && [ "$(tree_of "$SN/sandbox-v1")" = "$before_sandbox" ] \
  && [ "$(cat "$S/fs$SN/snapshots/atespaces/ate-golden/actors/t9/snapshots/g9/manifest.json")" = '{"v2":9}' ] \
  && [ "$(tree_of "$SN/snapshots/atespaces" | grep -c .)" = 6 ] \
  && grep -qE '^entry 1 4 [0-9]+ 4 [0-9]+$' <<<"$m" && ! grep -q '^found ' <<<"$m" \
  && ok "tree: both templates' snapshots copied and verified into platform/snapshots/, beside the files already there, which stay; nothing of either source touched" \
  || { bad "tree: state.1 '$(steps 1)', state.2 '$(steps 2)' (exit $rc)"; show; }
journal 20261117T120000Z "$SN/" "$SN/snapshots/" "$TMOVES" 2 $'delete 1\n' tree
run_applier || true
[ "$(last_step 1 | cut -d' ' -f2,4)" = "deleted 4" ] && [ ! -e "$S/fs$SN/counter-v1/atespaces" ] && [ -z "$(tree_of "$SN/counter-v1")" ] \
  && [ "$(tree_of "$SN/sandbox-v1")" = "$before_sandbox" ] && [ "$(tree_of "$SN/snapshots/atespaces" | grep -c .)" = 6 ] \
  && ok "tree: a delete of one verified template removes its files and folders alone" \
  || { bad "tree: delete 1: '$(last_step 1)'"; show; }

# --- The online pre-copy: precopy, final, unmark, mark, retire, discard -------------------------
# (ADR 0087, Updates, 2026-11-18.) line_of <n> <step>: move n's last line of
# that step. calls_from <count>: the calls after the first count.
line_of() { data infrared-store-moves "state.$1" | awk -v s="$2" '$2 == s { l = $0 } END { print l }'; }
calls_from() { tail -n "+$(($1 + 1))" "$S/calls"; }
ID=20261118T020000Z
MAN=/buckets/registry/.infrared-moves/$ID
new_state precopy
registry_repos
before="$(tree_of "$WEB")"
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 1\nprecopy 2\nmeasure delta\n'
rc=0
run_applier || rc=$?
m="$(data infrared-store-moves measured)"
p2="$(line_of 2 precopied)"
[ "$rc" = 0 ] && [ "$(steps 1)" = "precopying precopied" ] && [ "$(steps 2)" = "precopying precopied" ] \
  && [ "$(cut -d' ' -f4,6,8,9 <<<"$p2")" = "2 2 0 0" ] \
  && [ "$(cut -d' ' -f10 <<<"$p2")" = "$(sha256sum <"$S/fs$MAN/2.precopy.tsv" | cut -d' ' -f1)" ] \
  && [ "$(grep -c . "$S/fs$MAN/2.precopy.tsv")" = 2 ] \
  && [ "$(cd "$S/fs$NEW" && find . -type f ! -path './api/*' | LC_ALL=C sort | tr '\n' ' ')" = "$(printf './blobs/sha256/%s\n' "$B1" "$B2" | LC_ALL=C sort | tr '\n' ' ')" ] \
  && [ "$(tree_of "$NEW/blobs")" = "$(tree_of "$WEB/blobs")" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && grep -qE '^delta 2 3 [0-9]+$' <<<"$m" && grep -qE '^delta 1 1 [0-9]+$' <<<"$m" \
  && ok "precopy: each blob copied, given its source's time and verified, the manifest recorded by its SHA-256; no index.json, oci-layout or upload copied, the source untouched; the delta is the files a final takes: every one but the blobs" \
  || { bad "precopy: state.2 '$(steps 2)' ($p2), measured $m (exit $rc)"; show; }
# Zot serves on: a push adds a blob, its GC deletes another, a blob pushed
# again takes a new time. The next pass copies the new one, removes the copy
# of the one deleted, gives the third its new time, and reads no blob it
# verified before.
B3="$(blob "$WEB" layer-three 1700000300)"
unput "$WEB/blobs/sha256/$B2"
echo 1700000400 >"$S/mtime$WEB/blobs/sha256/$B1"
mark="$(grep -c . "$S/calls")"
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'precopy 2\n'
run_applier || true
p2="$(line_of 2 precopied)"
[ "$(cut -d' ' -f4,6,8,9 <<<"$p2")" = "2 1 1 0" ] \
  && [ "$(cd "$S/fs$NEW" && find . -type f ! -path './api/*' | LC_ALL=C sort | tr '\n' ' ')" = "$(printf './blobs/sha256/%s\n' "$B1" "$B3" | LC_ALL=C sort | tr '\n' ' ')" ] \
  && [ "$(cat "$S/mtime$NEW/blobs/sha256/$B1")" = 1700000400 ] && [ "$(tree_of "$NEW/blobs")" = "$(tree_of "$WEB/blobs")" ] \
  && ! calls_from "$mark" | grep -q "^s3 get $NEW/blobs/sha256/$B1$" && calls_from "$mark" | grep -q "^s3 get $NEW/blobs/sha256/$B3$" \
  && [ "$(calls_from "$mark" | grep -c '^s3 copy ')" = 1 ] \
  && ok "precopy: a pass after pushes copies only the new blob, removes the copy of the blob Zot deleted, moves a blob pushed again to its new time, and reads again no blob its manifest vouches for" \
  || { bad "precopy: the second pass: $p2"; show; }

# The window: Zot stopped, index.json changed since, a blob pushed after the
# last pass, another upload. final makes the destination the source and
# verifies it, reading no blob the pre-copy vouches for; unmark deletes the
# sources' oci-layout once verified.
put "$WEB/index.json" '{"schemaVersion":2,"manifests":[1,2]}' 1700000500
B4="$(blob "$WEB" layer-four 1700000501)"
put "$WEB/.uploads/u2" partial-two 1700000502
listing="$( (cd "$S/fs$WEB" && find . -type f ! -path './api/*' | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s %s %s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')" "$(sha256sum <"$f" | cut -d' ' -f1)" "$(cat "$S/mtime$WEB/$f")"; done) | sha256sum | cut -d' ' -f1)"
mark="$(grep -c . "$S/calls")"
journal "$ID" "$FROM" "$TO" "$MOVES" 3 $'final 1\nfinal 2\nunmark 1\nunmark 2\nmeasure\n'
rc=0
run_applier || rc=$?
v2="$(line_of 2 verified)"
[ "$rc" = 0 ] && [ "$(steps 2)" = "precopying precopied precopying precopied copying copied verified unmarking unmarked" ] \
  && [ "$(steps 1)" = "precopying precopied copying copied verified unmarked" ] \
  && [ "$(cut -d' ' -f4 <<<"$v2")" = 7 ] && [ "$(cut -d' ' -f6 <<<"$v2")" = "$listing" ] \
  && [ "$(cut -d' ' -f7 <<<"$v2")" = "$(sha256sum <"$S/fs$MAN/2.final.tsv" | cut -d' ' -f1)" ] \
  && [ "$(tree_of "$NEW" | grep -v '^./api/' | grep -v '^./oci-layout ')" = "$(tree_of "$WEB" | grep -v '^./api/')" ] \
  && [ "$(line_of 2 unmarked | cut -d' ' -f4)/$(line_of 1 unmarked | cut -d' ' -f4)" = 1/0 ] \
  && [ ! -e "$S/fs$WEB/oci-layout" ] && [ ! -e "$S/fs$WEB/api/oci-layout" ] && [ -f "$S/fs$NEW/oci-layout" ] \
  && ! calls_from "$mark" | grep -q "^s3 get $NEW/blobs/sha256/$B1$" && ! calls_from "$mark" | grep -q "^s3 get $NEW/blobs/sha256/$B3$" \
  && calls_from "$mark" | grep -q "^s3 get $NEW/blobs/sha256/$B4$" && [ "$(calls_from "$mark" | grep -c '^s3 copy ')" = 6 ] \
  && ok "final: with Zot stopped the destination becomes the source (index.json changed, a blob and an upload since), verified to the listing verify_move takes, reading no blob the pre-copy vouches for; unmark then deletes each verified source's oci-layout, whose copy is the same" \
  || { bad "final: state.2 '$(steps 2)' ($v2) (exit $rc)"; show; }

# The window undone: mark copies each oci-layout back, the same bytes and
# time.
journal "$ID" "$FROM" "$TO" "$MOVES" 4 $'mark 1\nmark 2\n'
run_applier || true
[ "$(steps 2 | awk '{ print $NF }')" = marked ] && [ "$(steps 1 | awk '{ print $NF }')" = unmarked ] \
  && [ "$(cat "$S/fs$WEB/oci-layout")" = '{"imageLayoutVersion":"1.0.0"}' ] && [ "$(cat "$S/mtime$WEB/oci-layout")" = 1700000101 ] \
  && [ "$(tree_of "$WEB" | grep -v '^./api/')" = "$(tree_of "$NEW" | grep -v '^./api/')" ] \
  && ok "mark: a window undone copies each oci-layout back from its verified copy, with its time: the source is whole again" \
  || { bad "mark: state.2 '$(steps 2)'"; show; }
journal "$ID" "$FROM" "$TO" "$MOVES" 5 $'unmark 1\nunmark 2\n'
run_applier || true

# Zot at the new root: it writes index.json there and deletes a blob. retire
# deletes each source, file by file, as verified, and counts the blob Zot
# deleted; a source changed since its verification is never deleted.
put "$NEW/index.json" '{"schemaVersion":2,"manifests":[1,2,3]}' 1700000600
unput "$NEW/blobs/sha256/$B3"
put "$WEB/api/blobs/sha256/extra" extra 1700000700
before_new="$(tree_of "$NEW")"
journal "$ID" "$FROM" "$TO" "$MOVES" 6 $'retire 1\nretire 2\nvacuum\n'
run_applier || true
[ "$(line_of 1 failed | cut -d' ' -f4-8)" = "its source is not what" ] && [ -f "$S/fs$WEB/api/index.json" ] \
  && [ "$(line_of 2 deleted | cut -d' ' -f4,5)" = "6 1" ] && [ -z "$(cd "$S/fs$WEB" && find . -type f ! -path './api/*')" ] \
  && [ -d "$S/fs$WEB/api" ] && [ ! -e "$S/fs$WEB/blobs" ] && [ "$(tree_of "$NEW")" = "$before_new" ] \
  && ! grep -E '^weed fs.rm (-r|-rf) ' "$S/calls" | grep -q . \
  && ok "retire: with Zot at the new root, a source as verified is deleted file by file with its empty folders, the blob Zot deleted since counted; a source that changed since its verification is not deleted; the destination untouched" \
  || { bad "retire: state.1 '$(steps 1)', state.2 '$(steps 2)' ($(line_of 2 deleted))"; show; }

# A retire killed after its first deletions: the next one deletes the rest of
# what was verified and records it.
new_state retire-resume
registry_repos
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\nfinal 2\nunmark 2\n'
run_applier || true
unput "$WEB/blobs/sha256/$B1"
unput "$WEB/index.json"
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'retire 2\n'
run_applier || true
[ "$(line_of 2 deleted | cut -d' ' -f4,5)" = "2 0" ] && [ -z "$(cd "$S/fs$WEB" && find . -type f ! -path './api/*')" ] \
  && ok "retire: a retire that stopped after some deletions is taken up: what is left is as verified, and goes" \
  || { bad "retire-resume: state.2 '$(steps 2)' ($(line_of 2 deleted))"; show; }

# A blob changed at the destination after its verification: nothing deleted.
new_state retire-changed
registry_repos
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\nfinal 2\nunmark 2\n'
run_applier || true
before="$(tree_of "$WEB")"
put "$NEW/blobs/sha256/$B1" other 1700000102
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'retire 2\n'
run_applier || true
[ "$(steps 2)" = "precopying precopied copying copied verified unmarking unmarked failed" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && [[ "$(line_of 2 failed)" == *"blobs/sha256/$B1 changed at the destination"* ]] \
  && ok "retire: a verified blob changed at the destination since deletes nothing of the source" \
  || { bad "retire-changed: state.2 '$(steps 2)'"; show; }

# Resilience: a copy refused and a copy that does not match leave the rest
# verified and their sources untouched; a pass killed midway is taken up.
new_state precopy-faults
registry_repos
before="$(tree_of "$WEB")"
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\n'
run_applier FAKE_COPY_FAIL="*/acme/images/web/blobs/sha256/$B1" FAKE_COPY_CORRUPT="*/acme/images/web/blobs/sha256/$B2" || true
p2="$(line_of 2 precopied)"
[ "$(cut -d' ' -f4,6,8,9 <<<"$p2")" = "0 1 1 2" ] && [[ "$p2" == *"could not be copied"* ]] \
  && [ -z "$(cd "$S/fs$NEW" 2>/dev/null && find . -type f)" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && ok "precopy: a copy refused is left for the next pass and a copy that does not match is removed, both counted unverified; the source untouched" \
  || { bad "precopy-faults: $p2"; show; }
new_state precopy-resume
registry_repos
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\n'
rc=0
run_applier FAKE_KILL_AFTER_COPIES=1 || rc=$?
stopped="$(steps 2)"
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'precopy 2\n'
run_applier || true
[ "$rc" != 0 ] && [ "$stopped" = precopying ] && [ "$(cut -d' ' -f4,6 <<<"$(line_of 2 precopied)")" = "2 1" ] \
  && [ "$(grep -c '^s3 copy ' "$S/calls")" = 2 ] && [ "$(tree_of "$NEW/blobs")" = "$(tree_of "$WEB/blobs")" ] \
  && ok "precopy: a pass killed after one copy is taken up: that copy kept and read, the other copied, both verified" \
  || { bad "precopy-resume: '$stopped' (exit $rc), then $(line_of 2 precopied)"; show; }

# Turned back: discard removes this migration's copies, where the source is
# there at the same size or the manifest vouches, and leaves anything else.
new_state discard
registry_repos
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\n'
run_applier || true
before="$(tree_of "$WEB")"
put "$NEW/blobs/sha256/foreign" foreign 1700000900
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'discard 2\n'
run_applier || true
[ "$(line_of 2 discarded | cut -d' ' -f4-6)" = "2 1 blobs/sha256/foreign" ] && [ "$(tree_of "$WEB")" = "$before" ] \
  && [ "$(cd "$S/fs$NEW" && find . -type f)" = ./blobs/sha256/foreign ] \
  && ok "discard: a move turned back loses this migration's copies, and a file it did not copy stays and is named; the source untouched" \
  || { bad "discard: $(line_of 2 discarded)"; show; }
journal "$ID" "$FROM" "$TO" "$MOVES" 3 $'final 2\nunmark 2\ndiscard 2\n'
run_applier || true
[ "$(steps 2 | awk '{ print $NF }')" = failed ] && [[ "$(line_of 2 failed)" == *"not back yet"* ]] && [ -f "$S/fs$NEW/index.json" ] \
  && ok "discard: a move whose oci-layout is not back at the source keeps its copy" \
  || { bad "discard: after unmark: '$(steps 2)'"; show; }
# Zot never served the destination: every file there is this migration's,
# a copy changed since too.
journal "$ID" "$FROM" "$TO" "$MOVES" 4 $'mark 2\n'
run_applier || true
put "$NEW/index.json" changed 1700000950
before="$(tree_of "$WEB")"
journal "$ID" "$FROM" "$TO" "$MOVES" 5 $'discard 2 own\n'
run_applier || true
[ "$(line_of 2 discarded | cut -d' ' -f5)" = 0 ] && [ -z "$(cd "$S/fs$NEW" 2>/dev/null && find . -type f ! -path './api/*')" ] \
  && [ "$(tree_of "$WEB")" = "$before" ] \
  && ok "discard: with own, every copy goes, one changed since too; the source untouched" \
  || { bad "discard own: $(line_of 2 discarded)"; show; }

# A repository Zot deleted while it was pre-copied: its copies go too.
new_state discard-gone
registry_repos
journal "$ID" "$FROM" "$TO" "$MOVES" 1 $'precopy 2\n'
run_applier || true
for f in index.json oci-layout "blobs/sha256/$B1" "blobs/sha256/$B2" .uploads/u1; do unput "$WEB/$f"; done
journal "$ID" "$FROM" "$TO" "$MOVES" 2 $'discard 2\n'
run_applier || true
[ "$(line_of 2 discarded | cut -d' ' -f4,5)" = "2 0" ] && [ -z "$(cd "$S/fs$NEW" 2>/dev/null && find . -type f ! -path './api/*')" ] \
  && ok "discard: the copies of a repository Zot deleted since go" \
  || { bad "discard-gone: $(steps 2)"; show; }

# The registry's alone: a tree journal asked to pre-copy stops.
new_state precopy-tree
journal "$ID" /buckets/ate-snapshots/platform/ /buckets/ate-snapshots/platform/snapshots/ $'1 a b snapshots - empty\n' 1 $'precopy 1\n' tree
rc=0
run_applier || rc=$?
[ "$rc" != 0 ] && [[ "$(data infrared-store-moves outcome)" == *"which only the registry's take"* ]] \
  && ok "precopy: a tree's journal is refused the registry's wants, and nothing is done" \
  || { bad "precopy-tree: exit $rc, $(data infrared-store-moves outcome)"; show; }

# --- Moving back: the repositories found ------------------------------------------------------
new_state rollback
put /buckets/registry/acme/images/web/index.json '{}' 1700000100
put /buckets/registry/zot/zot/acme/old/index.json '{}' 1700000100
put /buckets/registry/.uploads/x/0001.part part 1700000100
journal 20261117T130000Z /buckets/registry/ /buckets/registry/zot/zot/ $'1 acme/images/web acme/web images - empty\n' 1 $'measure\n'
run_applier || true
[ "$(data infrared-store-moves measured | grep '^found ' | tr '\n' ' ')" = "found acme/images/web " ] \
  && ok "rollback: moving back to the old root, the repositories found are the bucket's, none below the old root and not SeaweedFS's uploads" \
  || { bad "rollback: found '$(data infrared-store-moves measured | grep '^found ' | tr '\n' ' ')'"; show; }

# --- The sidecar writes the applier's keys alone ------------------------------------------------
new_state journal-keys
journal 20261117T101500Z "$FROM" "$TO" $'1 a b images - empty\n' 1 $'measure\n'
cm infrared-store-paths-applied '{}'
mkdir -p "$S/work/req"
{
  printf 'put\nwant\n20261117T101500Z\nmeasure\n' >"$S/work/req/000001"
  printf 'append\nid\n20261117T101500Z\nx\n' >"$S/work/req/000002"
  printf 'append\nstate.1x\n20261117T101500Z\nx\n' >"$S/work/req/000003"
  printf 'applied\n-\n-\n{"hash": "h", "id": "x"}\n' >"$S/work/req/000004"
  printf 'append\nstate.1\n19990101T000000Z\nx\n' >"$S/work/req/000005"
}
env PATH="$fakes:$PATH" FAKE_STATE="$S" WORK="$S/work" NAMESPACE=stores bash "$scripts/store-journal.sh" >"$S/journal.log" 2>&1 &
jpid=$!
for _ in $(seq 1 100); do [ -e "$S/work/res/000005" ] && break; sleep 0.1; done
kill "$jpid" 2>/dev/null || true
wait "$jpid" 2>/dev/null || true
answers="$(for n in 1 2 3 4 5; do head -c 5 "$S/work/res/00000$n" 2>/dev/null; echo; done | tr '\n' ' ')"
[ "$answers" = "error error error error stale " ] && [ "$(data infrared-store-moves want)" = measure ] \
  && [ "$(data infrared-store-moves id)" = 20261117T101500Z ] && [ "$(data infrared-store-paths-applied hash)" = "" ] \
  && ok "journal-keys: the sidecar refuses to write the operator's keys (want, id), a key no move has, and any key but the applier's in what it applied, and answers stale to another migration's id" \
  || bad "journal-keys: answers '$answers'"

exit "$fail"
