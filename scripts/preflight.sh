#!/usr/bin/env bash
# Show-day check, run 10+ minutes before going on stage. Everything must print OK.
set -uo pipefail
cd "$(dirname "$0")/.."
ok(){ printf '  OK   %s\n' "$*"; }; bad(){ printf '  FAIL %s\n' "$*"; FAILED=1; }; FAILED=0
docker info >/dev/null 2>&1 && ok "docker daemon" || bad "docker daemon not running"
kind get clusters 2>/dev/null | grep -qx finops && ok "kind cluster finops" || bad "kind cluster missing (make up)"
kubectl config use-context kind-finops >/dev/null 2>&1
np=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' | wc -l | tr -d ' '); [ "$np" = 0 ] && ok "all pods Running" || bad "$np pods not Running"
for u in 30080 30746/api/v1/info 30300/api/v1/version 30090/-/ready 30093/-/ready 30091; do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:$u); [ "$c" = 200 ] && ok "http :$u" || bad "http :$u -> $c"; done
for a in shop payments finops-policy; do s=$(kubectl -n argocd get app $a -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null); [ "$s" = "Synced/Healthy" ] && ok "argocd app $a $s" || bad "argocd app $a $s"; done
cpu=$(kubectl -n shop get deploy shop-api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null); [ "$cpu" = "2" ] && ok "shop-api at baseline (2 cores)" || bad "shop-api requests.cpu=$cpu (make reset)"
age=$(kubectl -n shop get pods -o jsonpath='{.items[0].status.startTime}' 2>/dev/null); ages=$(( $(date +%s) - $(date -u -j -f %FT%TZ "$age" +%s 2>/dev/null || echo 0) )); [ "$ages" -ge 120 ] && ok "shop-api pods ${ages}s old" || printf '  NOTE shop-api pods only %ss old (fine if coverage below is OK: old pods still count)\n' "$ages"
cov=$(curl -sG http://localhost:30090/api/v1/query --data-urlencode 'query=count_over_time((max(rate(container_cpu_usage_seconds_total{namespace="shop",container="shop-api"}[2m])))[10m:30s])' | jq -r '.data.result[0].value[1] // "0"' | cut -d. -f1); [ "$cov" -ge 10 ] && ok "usage signal coverage $cov/20" || bad "usage coverage $cov (<10): measure will block"
curl -s http://localhost:30090/api/v1/rules | jq -e '.data.groups[] | select(.name=="finops")' >/dev/null 2>&1 && ok "prometheus has the finops rule group loaded" || bad "finops rule group not loaded in prometheus (kubectl apply -f prom/cost-rule.yaml, wait ~60s)"
[ "$(kubectl get ns shop -o jsonpath='{.metadata.labels.finops-guard}' 2>/dev/null)" = "" ] && ok "shop not yet armed (no finops-guard label)" || bad "shop already has finops-guard label (make reset)"
curl -s http://localhost:30090/api/v1/query --data-urlencode 'query=kube_namespace_labels{namespace="shop"}' | jq -e '.data.result[0]' >/dev/null 2>&1 && ok "kube_namespace_labels exported" || bad "kube_namespace_labels missing (KSM allowlist)"
am=$(curl -s --max-time 3 http://localhost:30093/api/v2/alerts | jq 'length' 2>/dev/null || echo "?"); [ "$am" = 0 ] && ok "alertmanager empty" || bad "alertmanager alerts=$am (make reset restarts it; '?' = still starting)"
pr=$(curl -s 'http://localhost:30300/api/v1/repos/finops/gitops/pulls?state=open' | jq length); [ "$pr" = 0 ] && ok "no open PRs" || bad "$pr open PRs (make reset)"
wf=$(kubectl -n argo get wf --no-headers 2>/dev/null | grep -vc preview-ttl); [ "$wf" = 0 ] && ok "no rightsize workflows" || bad "$wf leftover workflows (make reset)"
es=$(kubectl -n argo-events get pods --no-headers | grep -cE 'eventsource|sensor'); [ "$es" = 2 ] && ok "eventsource + sensor pods" || bad "events pods: $es/2"
# every demo image must already be on the kind node, or an offline pod restart turns into ImagePullBackOff on stage
nodeimgs=$(docker exec finops-control-plane crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[]?')
missing=0; for i in $(cat images-*.txt | grep -v '^#' | grep -v '^$'); do ref=$i; case "$i" in */*) ;; *) ref="docker.io/library/$i";; esac; case "$i" in natsio/*|alpine/*) ref="docker.io/$i";; esac; echo "$nodeimgs" | grep -qx "$ref" || { missing=$((missing+1)); printf '       missing on node: %s\n' "$i"; }; done
[ "$missing" = 0 ] && ok "all $(cat images-*.txt | grep -cv '^#') demo images present on the kind node" || bad "$missing images missing on the node (make pull && make up reloads them)"
hostmissing=0; for i in $(cat images-*.txt | grep -v '^#' | grep -v '^$'); do docker image inspect "$i" >/dev/null 2>&1 || hostmissing=$((hostmissing+1)); done
[ "$hostmissing" = 0 ] && ok "all demo images cached in host Docker (survives make down)" || printf '  NOTE %s images not in host Docker: a rebuild would need network (make pull)\n' "$hostmissing"
pmset -g | grep -q 'sleep.*0' || printf '  NOTE caffeinate -dims not detected; run it before the talk\n'
mem=$(docker stats --no-stream --format '{{.MemUsage}}' finops-control-plane 2>/dev/null); printf '  INFO kind node memory %s\n' "$mem"
[ $FAILED = 0 ] && echo "PREFLIGHT OK" || { echo "PREFLIGHT FAILED"; exit 1; }
