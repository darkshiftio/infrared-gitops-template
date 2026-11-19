# The CNB launcher without its exec.d: what /cnb/lifecycle/launcher does for a
# buildpacks image before it runs a process, from the image's own layers, but
# none of the layers' exec.d programs. Agent Substrate 1.0's gVisor sandbox
# mounts no cgroup filesystem, and the Paketo node-engine buildpack's exec.d
# 0-optimize-memory reads the memory limit from it and fails, which stops the
# launcher before the process starts. Infrared's operator starts an actor's
# runner and agent through the same text (infrared-docs-internal ADR 0089).
#
#   sh -c "$(cat substrate-actor-launch.sh)" launch <program> [args...]
#
# Each layer's bin goes first on PATH, and its env and env.launch files apply
# as the launcher applies them (.default when unset, .override, .prepend and
# .append with .delim, a bare name as an override); then npm-install's exec.d
# 0-setup-symlinks's one job is done by hand: the app's node_modules is a link
# into /tmp that the launcher makes at start, to the layer that holds them.
set -e
for d in /layers/*/*; do
  [ -d "$d" ] || continue
  if [ -d "$d/bin" ]; then PATH="$d/bin:$PATH"; fi
  for e in "$d/env" "$d/env.launch"; do
    [ -d "$e" ] || continue
    for f in "$e"/*; do
      [ -f "$f" ] || continue
      k="${f##*/}"
      v="$(cat "$f")"
      case "$k" in
        *.delim) ;;
        *.default) k="${k%.default}"; [ -n "$(printenv "$k" || true)" ] || export "$k=$v" ;;
        *.override) export "${k%.override}=$v" ;;
        *.prepend) k="${k%.prepend}"; s="$(cat "$e/$k.delim" 2>/dev/null || true)"; export "$k=$v$s$(printenv "$k" || true)" ;;
        *.append) k="${k%.append}"; s="$(cat "$e/$k.delim" 2>/dev/null || true)"; export "$k=$(printenv "$k" || true)$s$v" ;;
        *) export "$k=$v" ;;
      esac
    done
  done
done
export PATH
t="$(readlink /workspace/node_modules 2>/dev/null || true)"
if [ -n "$t" ] && [ ! -e "$t" ]; then
  for m in /layers/*/*/node_modules; do
    if [ -d "$m" ]; then
      ln -s "$m" "$t"
      break
    fi
  done
fi
exec "$@"
