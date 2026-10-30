#!/usr/bin/env bash
# =============================================================================
# runner-egress-check.sh <kube context> <org>: runners' egress by name holds on
# a running install (infrared-docs-internal ADR 0066 D7; infrared-operator
# internal/controller/runner_egress.go).
# =============================================================================
# With the Infrared chart's runner.networkPolicy.egressByName on, an org's
# runner pods reach the internet only at the hosts the operator writes GKE
# FQDNNetworkPolicies for; in ir-org-<org>, for every runner pod, the model API
# and the install's hosts. This runs a probe pod there, labelled as a runner
# step's and placed as the install places agent steps (runner.placement: on a
# hosted plane the agents pool under GKE Sandbox), and passes when:
#
#   1. the operator runs with strict permissions and egress by name, and the
#      cluster serves FQDNNetworkPolicy;
#   2. the namespace holds the operator's policies: the runner NetworkPolicy
#      with no rule for the internet, and an FQDNNetworkPolicy for the model
#      API (the operator writes them when a step starts: run one step of the
#      org first);
#   3. from the probe: DNS answers, and HTTPS reaches the model API and every
#      host the namespace's policies name; it does not reach a host no policy
#      names, port 80 of an allowed host, the registry, infrared-mcp or cloud
#      metadata; it reaches Gitea when the org's forge is the install's Gitea;
#   4. a name that resolves to an address inside the cluster (the registry's
#      Service, a node), named by an FQDN policy of the check's own, still
#      does not reach it;
#   5. it records without judging each allowed host's address count (GKE takes
#      at most 50 for one policy), and whether an address learned for
#      registry.npmjs.org also serves another site by its name (a shared front
#      end, which an FQDN policy cannot tell apart).
#
# A refused call is a connection that never opens: it times out in 5 seconds.
# Every object the check makes is removed afterwards unless KEEP=1. It proves
# what kind and envtest cannot: GKE's FQDN network policy on Dataplane V2, on
# the sandboxed pool. Run it on the hosted plane after the install and one
# step, before a tenant, with the owner's go-ahead.
# Needs: kubectl, jq. Applies a probe pod and one FQDNNetworkPolicy in
# ir-org-<org>; public DNS for sslip.io.
# =============================================================================
set -euo pipefail
CTX="${1:?usage: scripts/runner-egress-check.sh <kube context> <org>}"
ORG="${2:?usage: scripts/runner-egress-check.sh <kube context> <org>}"
NS="ir-org-$ORG"
IMAGE=docker.io/alpine/k8s:1.37.0@sha256:b421c2e9419edb98db39b6ab641669f4db7bb2acf354f22450c6b7e7176d1ff4
INFRARED_NS="${INFRARED_NS:-infrared}"

k() { kubectl --context "$CTX" "$@"; }
log() { printf '\n== %s\n' "$*"; }
die() {
  echo "runner-egress-check: $*" >&2
  exit 1
}
fails=0
ok() { printf '  ok    %s\n' "$*"; }
bad() {
  printf '  FAIL  %s\n' "$*"
  fails=$((fails + 1))
}

# operator_env <name>: the operator's environment variable, or nothing.
operator_env() {
  k -n "$INFRARED_NS" get deployment infrared-operator -o json |
    jq -r --arg n "$1" '.spec.template.spec.containers[0].env[]? | select(.name == $n) | .value // empty'
}

log "1. the operator and the cluster"
k get namespace "$NS" >/dev/null 2>&1 || die "org $ORG has no namespace $NS on $CTX"
if [ "$(operator_env INFRARED_RUNNER_PERMISSIONS)" = strict ]; then ok "the operator runs agent steps with strict permissions"
else bad "INFRARED_RUNNER_PERMISSIONS is '$(operator_env INFRARED_RUNNER_PERMISSIONS)', want strict (the chart's runner.permissions)"; fi
egress="$(operator_env INFRARED_RUNNER_EGRESS)"
if [ -n "$egress" ]; then ok "the operator fences runners' egress by name: $(jq -c '.hosts' <<<"$egress")"
else die "INFRARED_RUNNER_EGRESS is not set: the chart's runner.networkPolicy.egressByName is off"; fi
if k api-resources --api-group=networking.gke.io -o name 2>/dev/null | grep -q '^fqdnnetworkpolicies'; then
  ok "the cluster serves FQDNNetworkPolicy"
else die "the cluster serves no FQDNNetworkPolicy: turn on GKE's FQDN network policy (infrared-iac-modules fqdn_network_policy)"; fi
placement="$(operator_env INFRARED_AGENT_STEP_PLACEMENT)"
[ -n "$placement" ] || placement='{}'
echo "  agent steps run with placement $(jq -c '{nodeSelector, tolerations, runtimeClassName}' <<<"$placement")"

log "2. the operator's policies in $NS"
policy="$(k -n "$NS" get networkpolicy infrared-runner -o json 2>/dev/null)" ||
  die "$NS has no NetworkPolicy infrared-runner: run one agent step of org $ORG first"
if [ "$(jq '[.spec.egress[]?.to[]?.ipBlock.cidr // empty] | index("0.0.0.0/0")' <<<"$policy")" = null ]; then
  ok "infrared-runner has no rule for the internet"
else bad "infrared-runner still allows the internet on 80 and 443"; fi
gitea=no
if jq -e '[.spec.egress[]?.to[]?.podSelector.matchLabels["app.kubernetes.io/name"] // empty] | index("gitea")' <<<"$policy" >/dev/null; then
  gitea=yes
fi
allowed="$(k -n "$NS" get fqdnnetworkpolicies -l infrared.darkshift.io/runner-egress=namespace -o json |
  jq -r '[.items[].spec.egress[0].matches[0] | .name // .pattern] | join(" ")')"
case " $allowed " in
*" api.anthropic.com "*) ok "FQDNNetworkPolicies for every runner pod: $allowed" ;;
*) die "$NS has no FQDNNetworkPolicy for api.anthropic.com: run one agent step of org $ORG first" ;;
esac

stamp="$(date -u +%Y%m%d-%H%M%S)"
probe="runner-egress-check-$stamp"
mine="runner-egress-check-$stamp"
cleanup() {
  k -n "$NS" delete pod "$probe" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k -n "$NS" delete fqdnnetworkpolicy "$mine" --ignore-not-found >/dev/null 2>&1 || true
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT

# Addresses inside the cluster, by public names that resolve to them (sslip.io),
# for the check's own FQDN policy: the registry's Service and a node.
zot_ip="$(k -n registry get service zot -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
node_ip="$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
inside=()
[ -n "$zot_ip" ] && inside+=("${zot_ip//./-}.sslip.io 5000 the registry's Service by a public name")
[ -n "$node_ip" ] && inside+=("${node_ip//./-}.sslip.io 10250 a node's kubelet by a public name")
if [ "${#inside[@]}" -gt 0 ]; then
  matches="$(for i in "${inside[@]}"; do jq -n --arg n "${i%% *}" '{name: $n}'; done | jq -s -c .)"
  k apply -f - >/dev/null <<EOF
apiVersion: networking.gke.io/v1alpha1
kind: FQDNNetworkPolicy
metadata:
  name: $mine
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: runner-egress-check
spec:
  podSelector:
    matchLabels:
      infrared.darkshift.io/run: $probe
  egress:
    - matches: $matches
EOF
else
  echo "  no registry Service or node address found: step 4 is left out"
fi

# The probe's script: DNS, the allowed hosts, the refused ones, the names that
# resolve inside, and what is recorded without judging.
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
script='
rc=0
https() { curl -s -m 10 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || true; }
reaches() { c="$(https "https://$1/")"; if [ "$c" != 000 ]; then echo "  ok    https://$1 answers ($c)"; else echo "  FAIL  https://$1 refused"; rc=1; fi; }
refused_url() { c="$(https "$1")"; if [ "$c" = 000 ]; then echo "  ok    $1 refused"; else echo "  FAIL  $1 answered ($c)"; rc=1; fi; }
refused() { if nc -z -w 5 "$1" "$2" 2>/dev/null; then echo "  FAIL  $3 ($1:$2) accepted a connection"; rc=1; else echo "  ok    $3 ($1:$2) refused"; fi; }
sleep 5
if nslookup api.anthropic.com >/dev/null 2>&1; then echo "  ok    DNS answers"; else echo "  FAIL  DNS does not answer"; rc=1; fi
for h in '"$allowed"'; do case "$h" in \*.*) ;; *) reaches "$h" ;; esac; done
refused_url https://example.com/
refused_url http://proxy.golang.org/
refused zot.registry.svc.cluster.local 5000 "the registry (no publish label)"
refused infrared-mcp.'"$INFRARED_NS"'.svc.cluster.local 8081 "infrared-mcp (no MCP label)"
refused 169.254.169.254 80 "cloud metadata"
'
if [ "$gitea" = yes ]; then
  script="$script"'
if nc -z -w 5 gitea-http.'"$INFRARED_NS"'.svc.cluster.local 3000 2>/dev/null; then echo "  ok    Gitea (3000) reached"; else echo "  FAIL  Gitea (3000) refused"; rc=1; fi
'
fi
for i in "${inside[@]+"${inside[@]}"}"; do
  read -r name port what <<<"$i"
  script="$script"'refused '"$name $port"' "'"$what"'"
'
done
# shellcheck disable=SC2016 # expanded in the probe's shell, not here
script="$script"'
echo "  recorded: addresses each allowed host resolves to (GKE takes at most 50 for one policy)"
for h in '"$allowed"'; do case "$h" in \*.*) ;; *) echo "    $h: $(nslookup "$h" 2>/dev/null | awk "/^Name:/ {n=1} n && /^Address/ {c++} END {print c+0}")" ;; esac; done
npm="$(nslookup registry.npmjs.org 2>/dev/null | awk "/^Name:/ {n=1} n && /^Address: [0-9.]+$/ {print \$2; exit}")"
if [ -n "$npm" ]; then
  c="$(curl -s -m 10 -o /dev/null -w "%{http_code}" --resolve "www.cloudflare.com:443:$npm" https://www.cloudflare.com/ 2>/dev/null || true)"
  echo "  recorded: an address learned for registry.npmjs.org ($npm) serving www.cloudflare.com answers $c (000: refused)"
fi
exit $rc
'

log "3-5. from a probe labelled as a runner step of org $ORG"
jq -n --arg ns "$NS" --arg name "$probe" --arg image "$IMAGE" --arg script "$script" --argjson p "$placement" '
  {apiVersion: "v1", kind: "Pod",
   metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/part-of": "runner-egress-check",
     "infrared.darkshift.io/run": $name, "infrared.darkshift.io/step": "probe"}},
   spec: ({restartPolicy: "Never", automountServiceAccountToken: false, enableServiceLinks: false,
     securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: "RuntimeDefault"}},
     containers: [{name: "probe", image: $image, command: ["/bin/sh", "-c", $script],
       securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}}]}
     + (if $p.nodeSelector then {nodeSelector: $p.nodeSelector} else {} end)
     + (if $p.tolerations then {tolerations: $p.tolerations} else {} end)
     + (if $p.runtimeClassName then {runtimeClassName: $p.runtimeClassName} else {} end))}' | k apply -f - >/dev/null
phase=""
deadline=$((SECONDS + 600))
while [ "$SECONDS" -lt "$deadline" ]; do
  phase="$(k -n "$NS" get pod "$probe" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded | Failed) break ;; esac
  sleep 5
done
echo "  the probe ran on node $(k -n "$NS" get pod "$probe" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)" \
  "under runtime class '$(k -n "$NS" get pod "$probe" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || true)'"
k -n "$NS" logs "$probe" 2>/dev/null || true
if [ "$phase" = Succeeded ]; then ok "the probe passed"; else bad "the probe ended $phase"; fi

echo
if [ "$fails" -gt 0 ]; then echo "runner-egress-check: $fails check(s) FAILED"; exit 1; fi
echo "runner-egress-check: runners' egress by name holds in $NS"
