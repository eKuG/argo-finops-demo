#!/usr/bin/env bash
# Return the demo to its starting state in under a minute: git main = baseline, no PRs/branches/issues,
# no workflows, alert rule disarmed, Alertmanager state cleared, preview namespaces re-seeded.
set -euo pipefail
cd "$(dirname "$0")/.."
TOKEN=$(cat .local/gitea-token)
G=http://localhost:30300/api/v1/repos/finops/gitops
H=(-H "Authorization: token $TOKEN" -H "Content-Type: application/json")

echo "- git: main <- baseline, close PRs, delete finops/* branches, close issues"
tmp=$(mktemp -d)
git clone -q --branch baseline "http://finops:finops-demo-2026@localhost:30300/finops/gitops.git" "$tmp"
git -C "$tmp" push -q -f origin baseline:main
rm -rf "$tmp"
for n in $(curl -s "${H[@]}" "$G/pulls?state=open&limit=50" | jq -r '.[].number'); do
  curl -s "${H[@]}" -X PATCH "$G/pulls/$n" -d '{"state":"closed"}' >/dev/null; done
for b in $(curl -s "${H[@]}" "$G/branches?limit=100" | jq -r '.[].name | select(startswith("finops/")) | @uri'); do
  curl -s "${H[@]}" -X DELETE "$G/branches/$b" >/dev/null; done
for i in $(curl -s "${H[@]}" "$G/issues?state=open&type=issues&limit=50" | jq -r '.[].number'); do
  curl -s "${H[@]}" -X PATCH "$G/issues/$i" -d '{"state":"closed"}' >/dev/null; done

echo "- cluster: disarm the guardrail (namespace label), clear Alertmanager, delete workflows, resync Argo CD"
kubectl label ns shop finops-guard- >/dev/null 2>&1 || true
kubectl -n monitoring delete pod -l app.kubernetes.io/name=alertmanager --wait=false >/dev/null 2>&1 || true
kubectl -n argo delete wf --all --wait=false >/dev/null
for a in shop payments finops-policy; do kubectl -n argocd annotate app "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null; done

echo "- preview namespaces re-seeded (pr-41 expires in 3 min, pr-42 in 9 min)"
for p in 41 42; do kubectl delete ns preview-pr-$p --ignore-not-found --wait=true >/dev/null 2>&1 || true; done
for p in 41 42; do
  kubectl create ns preview-pr-$p >/dev/null
  kubectl label ns preview-pr-$p preview=true >/dev/null
  kubectl annotate ns preview-pr-$p finops/expires-at="$(date -u -v+$((p == 41 ? 3 : 9))M +%FT%TZ)" >/dev/null
done

echo "- waiting for shop-api back at baseline requests"
kubectl -n shop rollout status deploy/shop-api --timeout=90s >/dev/null
kubectl -n shop get deploy shop-api -o jsonpath='  shop-api requests: cpu={.spec.template.spec.containers[0].resources.requests.cpu} mem={.spec.template.spec.containers[0].resources.requests.memory}{"\n"}'
echo "reset done"
