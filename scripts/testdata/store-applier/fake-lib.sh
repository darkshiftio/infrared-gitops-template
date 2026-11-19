#!/usr/bin/env bash
# Sourced by the fakes of scripts/store-applier-test.sh: a pretend SeaweedFS
# kept in FAKE_STATE.
#
#   fs/<filer path>     each file's content, each folder a directory
#   mtime/<filer path>  each file's modification time, Unix seconds
#   size/<filer path>   a file's size, where the filer lists it so without
#                       its content holding as many bytes: one too large to
#                       write, which nothing may read or copy
#   conf.json           the filer's path rules, {"locations": [...]}
#   cm/<name>.json      each ConfigMap of the namespace stores
#   calls               every call the fakes took, a line each
#   volumes.json        the master's topology; status/<id>.json each volume
#                       server's /status
set -euo pipefail
STATE="${FAKE_STATE:?the fakes need FAKE_STATE}"

called() { printf '%s\n' "$*" >>"$STATE/calls"; }

# mtime_of <filer path>
mtime_of() { cat "$STATE/mtime$1" 2>/dev/null || echo 0; }
set_mtime() { mkdir -p "$(dirname "$STATE/mtime$1")"; printf '%s\n' "$2" >"$STATE/mtime$1"; }

# size_of <filer path>: its size as given, else its content's.
size_of() {
  if [ -f "$STATE/size$1" ]; then cat "$STATE/size$1"; else wc -c <"$STATE/fs$1" | tr -d ' '; fi
}

# chunks_of <filer path>: the file's one chunk, named by its content, as the
# filer would list it.
chunks_of() {
  local id
  id="$(sha256sum <"$STATE/fs$1" | cut -c1-16)"
  jq -cn --arg id "$id" --arg size "$(size_of "$1")" '[{fileId: $id, size: $size, fid: {volumeId: 3, fileKey: "77", cookie: 99}}]'
}

# entry_json <filer path> <omit chunks: true|false>
entry_json() {
  local p=$1 name
  name="$(basename "$p")"
  if [ -d "$STATE/fs$p" ]; then
    jq -cn --arg n "$name" '{name: $n, isDirectory: true, attributes: {mtime: "1700000000", fileMode: 2147484141}}'
  elif [ "$2" = true ]; then
    jq -cn --arg n "$name" --arg s "$(size_of "$p")" --arg m "$(mtime_of "$p")" \
      '{name: $n, attributes: {fileSize: $s, mtime: $m, fileMode: 432}}'
  else
    jq -cn --arg n "$name" --arg s "$(size_of "$p")" --arg m "$(mtime_of "$p")" --argjson c "$(chunks_of "$p")" \
      '{name: $n, chunks: $c, attributes: {fileSize: $s, mtime: $m, fileMode: 432}}'
  fi
}

# rm_meta <filer path>: forgets the times and sizes below a removed path.
rm_meta() {
  if [ -e "$STATE/mtime$1" ]; then rm -r "$STATE/mtime$1"; fi
  if [ -e "$STATE/size$1" ]; then rm -r "$STATE/size$1"; fi
}
