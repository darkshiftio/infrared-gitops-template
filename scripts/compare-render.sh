#!/usr/bin/env bash
# =============================================================================
# compare-render.sh <ref> [flags for both renders] [-- flags for this tree only]
#                   [--ref flags for <ref> only]
# =============================================================================
# Proves that a change to the template renders today's files unchanged. It
# renders <ref> (with its own hack/render) and this working tree, and fails
# unless:
#   - every file <ref> renders that holds objects is rendered by this tree
#     too, byte for byte, and every other file <ref> renders either is, or is
#     no longer rendered (a component file that held no objects, removed);
#   - every file only this tree renders holds no objects (comments only: the
#     rendering contract always writes a file, so a new component that is off
#     still appears).
# Flags before `--` go to both renders; flags after it to this tree's only,
# e.g. Data fields <ref> does not know; flags after `--ref` to <ref>'s only,
# e.g. the Data fields a renamed field had there:
#
#   scripts/compare-render.sh origin/main
#   scripts/compare-render.sh origin/main -flavor eks -region us-west-2
#   scripts/compare-render.sh origin/main -- -platform-domain preprod.example.com
#   scripts/compare-render.sh origin/main -stores -- -postgres-archive '{"retention": "14d"}' \
#     --ref -copies '{"postgres": {"retention": "14d"}}'
#
# Needs: git, go, yq (mikefarah v4).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:?usage: scripts/compare-render.sh <ref> [flags for both] [-- flags for this tree only]}"
shift
both=()
mine=()
theirs=()
to=both
while [ $# -gt 0 ]; do
  case "$1" in
    --) to=mine ;;
    --ref) to=theirs ;;
    *)
      case "$to" in
        both) both+=("$1") ;;
        mine) mine+=("$1") ;;
        theirs) theirs+=("$1") ;;
      esac
      ;;
  esac
  shift
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref-src"
git archive --format=tar "$ref" | tar -x -C "$work/ref-src"
(cd "$work/ref-src" && go run ./hack/render -template template -out "$work/ref" ${both[@]+"${both[@]}"} ${theirs[@]+"${theirs[@]}"}) >/dev/null
go run ./hack/render -template template -out "$work/tree" ${both[@]+"${both[@]}"} ${mine[@]+"${mine[@]}"} >/dev/null

# objects <file>: true when the file holds at least one object.
objects() { [ -n "$(yq -N -r '.kind // ""' "$1" 2>/dev/null | grep -v '^$' || true)" ]; }

fail=0
same=0
gone=0
while IFS= read -r f; do
  if [ ! -e "$work/tree/$f" ]; then
    if objects "$work/ref/$f"; then
      echo "FAIL: $f is no longer rendered"
      fail=1
    else
      gone=$((gone + 1))
      echo "removed, no objects: $f"
    fi
  elif cmp -s "$work/ref/$f" "$work/tree/$f"; then
    same=$((same + 1))
  else
    echo "FAIL: $f differs:"
    diff "$work/ref/$f" "$work/tree/$f" | head -n 20 || true
    fail=1
  fi
done < <(cd "$work/ref" && find . -type f | sed 's#^\./##' | sort)

new=0
while IFS= read -r f; do
  [ -e "$work/ref/$f" ] && continue
  new=$((new + 1))
  if objects "$work/tree/$f"; then
    echo "FAIL: $f is new and holds objects"
    fail=1
  else
    echo "new, no objects: $f"
  fi
done < <(cd "$work/tree" && find . -type f | sed 's#^\./##' | sort)

echo "$same files the same byte for byte as $ref ($(git rev-parse --short "$ref")); $new new; $gone removed"
if [ "$fail" -ne 0 ]; then
  echo "compare-render: FAILED" >&2
  exit 1
fi
echo "compare-render: today's files render unchanged"
