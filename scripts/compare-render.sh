#!/usr/bin/env bash
# =============================================================================
# compare-render.sh <ref> [flags for both renders] [-- flags for this tree only]
# =============================================================================
# Proves that a change to the template renders today's files unchanged. It
# renders <ref> (with its own hack/render) and this working tree, and fails
# unless:
#   - every file <ref> renders is rendered by this tree too, byte for byte;
#   - every file only this tree renders holds no objects (comments only: the
#     rendering contract always writes a file, so a new component that is off
#     still appears).
# Flags before `--` go to both renders; flags after it to this tree's only,
# e.g. Data fields <ref> does not know:
#
#   scripts/compare-render.sh origin/main
#   scripts/compare-render.sh origin/main -flavor eks -region us-west-2
#   scripts/compare-render.sh origin/main -- -platform-domain preprod.example.com
#
# Needs: git, go, yq (mikefarah v4).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:?usage: scripts/compare-render.sh <ref> [flags for both] [-- flags for this tree only]}"
shift
both=()
mine=()
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then
    shift
    mine=("$@")
    break
  fi
  both+=("$1")
  shift
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref-src"
git archive --format=tar "$ref" | tar -x -C "$work/ref-src"
(cd "$work/ref-src" && go run ./hack/render -template template -out "$work/ref" ${both[@]+"${both[@]}"}) >/dev/null
go run ./hack/render -template template -out "$work/tree" ${both[@]+"${both[@]}"} ${mine[@]+"${mine[@]}"} >/dev/null

fail=0
same=0
while IFS= read -r f; do
  if [ ! -e "$work/tree/$f" ]; then
    echo "FAIL: $f is no longer rendered"
    fail=1
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
  if [ -n "$(yq -N -r '.kind // ""' "$work/tree/$f" 2>/dev/null | grep -v '^$' || true)" ]; then
    echo "FAIL: $f is new and holds objects"
    fail=1
  else
    echo "new, no objects: $f"
  fi
done < <(cd "$work/tree" && find . -type f | sed 's#^\./##' | sort)

echo "$same files the same byte for byte as $ref ($(git rev-parse --short "$ref")); $new new"
if [ "$fail" -ne 0 ]; then
  echo "compare-render: FAILED" >&2
  exit 1
fi
echo "compare-render: today's files render unchanged"
