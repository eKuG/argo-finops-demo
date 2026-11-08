#!/usr/bin/env bash
# Push the local gitops/ tree to Gitea as `main` and `baseline` (force). Used by up.sh; re-run after editing gitops/.
set -euo pipefail
cd "$(dirname "$0")/.."
GITEA_USER=${GITEA_USER:-finops}; GITEA_PW=${GITEA_PW:-finops-demo-2026}
tmp=$(mktemp -d); cp -R gitops/. "$tmp"
git -C "$tmp" init -q -b main && git -C "$tmp" add -A && git -C "$tmp" -c user.name=finops -c user.email=finops@example.com commit -qm "baseline: shop, payments, finops policy"
git -C "$tmp" push -q -f "http://$GITEA_USER:$GITEA_PW@localhost:30300/finops/gitops.git" main main:baseline
rm -rf "$tmp"
echo "seeded finops/gitops main + baseline"
