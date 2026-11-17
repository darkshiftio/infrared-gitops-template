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
