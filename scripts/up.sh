#!/usr/bin/env bash
# Bring up the whole demo on kind, offline-safe. Idempotent: re-run after a partial failure.
set -euo pipefail
cd "$(dirname "$0")/.."
GITEA_USER=finops
GITEA_PW=finops-demo-2026
ARGOCD_PW=finops-demo-2026
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
nsup() { kubectl create ns "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

log "kind cluster"
kind get clusters 2>/dev/null | grep -qx finops || kind create cluster --config kind-config.yaml --wait 120s
kubectl config use-context kind-finops >/dev/null

log "load images into kind"
imgs=$(cat images-*.txt | grep -v '^#' | grep -v '^$')
have=$(docker exec finops-control-plane crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[]?' || true)
missing=""
for i in $imgs; do
  ref=$i; case "$i" in */*) ;; *) ref="docker.io/library/$i";; esac
  case "$i" in natsio/*|alpine/*) ref="docker.io/$i";; esac
  echo "$have" | grep -qx "$ref" || missing="$missing $i"
done
if [ -n "$missing" ]; then
  echo "loading:$missing"
  # Docker Desktop's containerd store exports multi-arch indexes that `kind load docker-image` can't import; save one platform.
  for i in $missing; do
    docker save --platform linux/arm64 "$i" -o /tmp/kind-img.tar && kind load image-archive --name finops /tmp/kind-img.tar >/dev/null && echo "  loaded $i"
  done
  rm -f /tmp/kind-img.tar
else
  echo "all images present"
fi

log "argo cd"
nsup argocd
sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' vendor/manifests/acd-install.yaml | kubectl -n argocd apply --server-side --force-conflicts -f - >/dev/null
kubectl -n argocd apply -f argocd/patches.yaml >/dev/null
HASH=$(argocd account bcrypt --password "$ARGOCD_PW")
kubectl -n argocd patch secret argocd-secret -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}" >/dev/null
kubectl -n argocd scale deploy argocd-dex-server --replicas=0 >/dev/null
kubectl -n argocd rollout restart deploy argocd-server >/dev/null
kubectl -n argocd rollout restart statefulset argocd-application-controller >/dev/null   # timeout.reconciliation is read at controller start
# repo-server caches `git ls-remote` for 3m by default (no ConfigMap knob wired in 3.5.6): a merged PR would wait minutes
kubectl -n argocd set env deploy/argocd-repo-server ARGOCD_REVISION_CACHE_EXPIRATION=5s >/dev/null

log "argo workflows"
nsup argo
kubectl -n argo apply --server-side --force-conflicts -f vendor/manifests/aw-install.yaml >/dev/null
kubectl -n argo patch deploy argo-server --type json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["server","--auth-mode=server","--secure=false"]},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/scheme","value":"HTTP"}]' >/dev/null
kubectl -n argo patch svc argo-server -p '{"spec":{"type":"NodePort","ports":[{"name":"web","port":2746,"targetPort":2746,"nodePort":30746}]}}' >/dev/null
kubectl -n argo patch cm workflow-controller-configmap --type merge -p '{"data":{"executor":"imagePullPolicy: IfNotPresent\n"}}' >/dev/null
kubectl -n argo rollout restart deploy workflow-controller >/dev/null
kubectl wait --for=condition=Established crd/workflows.argoproj.io crd/workflowtemplates.argoproj.io crd/cronworkflows.argoproj.io --timeout=90s >/dev/null
kubectl apply -f workflows/ >/dev/null

log "argo events"
nsup argo-events
sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' vendor/manifests/ae-install.yaml | kubectl apply --server-side --force-conflicts -f - >/dev/null
kubectl -n argo-events set env deploy/controller-manager IMAGE_PULL_POLICY=IfNotPresent >/dev/null
kubectl wait --for=condition=Established crd/eventbus.argoproj.io crd/eventsources.argoproj.io crd/sensors.argoproj.io --timeout=90s >/dev/null
kubectl apply -f events/eventbus.yaml -f events/rbac.yaml >/dev/null

log "prometheus + alertmanager"
nsup monitoring
helm upgrade --install kps vendor/charts/kube-prometheus-stack-92.17.0.tgz -n monitoring -f values/kps.yaml --wait --timeout 6m >/dev/null
kubectl apply -f prom/cost-rule.yaml >/dev/null   # loaded once; the demo arms it per namespace with a label

log "opencost"
nsup opencost
helm upgrade --install opencost vendor/charts/opencost-2.5.33.tgz -n opencost -f values/opencost.yaml --wait --timeout 3m >/dev/null

log "gitea"
nsup gitea
helm upgrade --install gitea vendor/charts/gitea-12.7.0.tgz -n gitea -f values/gitea.yaml --wait --timeout 6m >/dev/null
until curl -sf http://localhost:30300/api/v1/version >/dev/null; do sleep 2; done
API=http://localhost:30300/api/v1
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PW" -H 'Content-Type: application/json' \
  -X POST "$API/user/repos" -d '{"name":"gitops","default_branch":"main","auto_init":false,"private":false}')
[ "$code" = 201 ] || [ "$code" = 409 ] || { echo "repo create failed: $code"; exit 1; }
GITEA_USER=$GITEA_USER GITEA_PW=$GITEA_PW ./scripts/seed-git.sh >/dev/null
TOKEN=$(curl -sf -u "$GITEA_USER:$GITEA_PW" -H 'Content-Type: application/json' -X POST "$API/users/$GITEA_USER/tokens" \
  -d "{\"name\":\"argo-$(date +%s)\",\"scopes\":[\"write:repository\",\"write:issue\",\"read:user\"]}" | jq -r .sha1)
kubectl -n argo create secret generic gitea-token --from-literal=token="$TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
mkdir -p .local && printf '%s' "$TOKEN" > .local/gitea-token && chmod 600 .local/gitea-token

log "argo cd applications"
kubectl apply -f argocd/repo-and-apps.yaml >/dev/null

log "argo events wiring"
kubectl -n argo-events wait --for=condition=Deployed eventbus/default --timeout=180s >/dev/null
kubectl apply -f events/eventsource.yaml -f events/sensor.yaml >/dev/null

log "preview namespaces (TTL demo)"
for p in 41 42; do
  nsup preview-pr-$p
  kubectl label ns preview-pr-$p preview=true --overwrite >/dev/null
  kubectl annotate ns preview-pr-$p finops/expires-at="$(date -u -v+$((p == 41 ? 3 : 9))M +%FT%TZ)" --overwrite >/dev/null
done

log "waiting for workloads"
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy app/shop app/payments app/finops-policy --timeout=240s >/dev/null || true
kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' || true

cat <<EOF

Argo CD       http://localhost:30080   admin / $ARGOCD_PW
Argo Workflows http://localhost:30746
Gitea         http://localhost:30300   $GITEA_USER / $GITEA_PW   repo: finops/gitops
Prometheus    http://localhost:30090
Alertmanager  http://localhost:30093
OpenCost      http://localhost:30091
EventSource   http://localhost:30120/alerts   (manual fallback: make demo-fake)
EOF
