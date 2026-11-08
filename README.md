# Cost-Aware GitOps demo rig

Everything for the ArgoCon NA 2026 talk runs on one kind node on a laptop, with Wi-Fi off.

```
make pull     # once, with network: pulls ~5 GB of images into Docker
make up       # creates kind cluster `finops`, loads images, installs everything, seeds Gitea
make reset    # back to the starting state in < 60 s (between rehearsals)
make down     # deletes the cluster; images stay in Docker
```

| Component | Version | URL |
|---|---|---|
| Argo CD | 3.5.6 | http://localhost:30080 (admin / finops-demo-2026) |
| Argo Workflows | 4.1.6 | http://localhost:30746 |
| Argo Events | 1.9.11 | webhook at http://localhost:30120/alerts |
| Prometheus / Alertmanager | kube-prometheus-stack 92.17.0 | http://localhost:30090 / :30093 |
| OpenCost | 1.121.3 | http://localhost:30091 |
| Gitea | 1.27 | http://localhost:30300 (finops / finops-demo-2026), repo `finops/gitops` |

## The loop

```
shop-api (3 × 2000m request, ~2m used)  ──cAdvisor/KSM──▶  Prometheus
                                                                │ rule OverProvisioned (<10% for 30s)
                                                                ▼
                                                          Alertmanager ──webhook──▶ Argo Events EventSource
                                                                                           │
                                                                                     Sensor (filter firing; labels → params)
                                                                                           │ submit from WorkflowTemplate
                                                                                           ▼
                                          Argo Workflow `rightsize`: measure → policy → open-pr → approve → merge
                                                                                           │ Gitea PR merged to main
                                                                                           ▼
                                                                          Argo CD (10 s reconcile, selfHeal) syncs shop-api
```

## Demo beats

| Beat | Command | What the room sees |
|---|---|---|
| Hook | `make demo-hook` | `kubectl set resources` → Argo CD selfHeal reverts it within ~10 s |
| A | `make demo-arm` | `kubectl label ns shop finops-guard=on` → alert → Sensor → Workflow → PR in Gitea with evidence (~50–65 s) |
| B | Argo UI → Resume → YES (or `make demo-approve`) | Merge → Argo CD sync → Prometheus $ run-rate drops |
| C | `make demo-block` | Same template on `payments` → policy freeze → workflow fails → Gitea issue |
| D | `make demo-ttl` | CronWorkflow deleting expired `preview-pr-*` namespaces |

Fallback triggers for Beat A, same code path: `make demo-fake` (POST a fake Alertmanager payload to the EventSource), `make demo-submit` (skip Events entirely).

## Layout

```
kind-config.yaml       NodePorts → localhost
images-*.txt           every image, pinned; scripts/pull-images.sh pulls them
values/                Helm values: kps (Prometheus+Alertmanager), opencost, gitea
vendor/                pinned install manifests + chart tgz (offline)
argocd/                repo Secret, Applications (shop, payments, finops-policy), demo patches
events/                EventBus, webhook EventSource, Sensor, RBAC
workflows/             WorkflowTemplate rightsize, CronWorkflow preview-ttl, RBAC
prom/cost-rule.yaml    the PrometheusRule (loaded at install, gated per namespace by the finops-guard label)
gitops/                seed of the Gitea repo (what Argo CD syncs); `baseline` branch = reset point
scripts/               up.sh, reset.sh, pull-images.sh, fake-alert.json
```

## Runbook notes (measured 2026-11-02)

- `make up` from nothing: ~8 min (image load dominates). `make reset`: 5 s. Hook revert (selfHeal): 2 s.
- Beat A over the real alert path: the rule is always loaded and gated on `kube_namespace_labels{label_finops_guard="on"}`; arming is `kubectl label ns shop finops-guard=on` (≤15 s KSM scrape + ≤15 s eval + 30 s `for` + 5 s group_wait; measured **42–51 s**), then **30 s** to the approve gate (three step pods). Applying the PrometheusRule live instead went through the operator/kubelet volume sync and varied 64–127 s. Fill the first wait with the Sensor YAML.
- Beat B: resume → merge → Argo CD sync → rolled out **16–31 s**. This needs `ARGOCD_REVISION_CACHE_EXPIRATION=5s` on the repo-server (set by `up.sh`); the default 3 m cache made it 110 s.
- The measure step refuses to act on < 10 usage samples in the window (5 min at 30 s). The *workload* needs 5+ min of history in the last 10 min; a pod restart (the hook) does not reset it because old pods still count. Fresh `make up` or a long-idle cluster: wait 7 min before Beat A. `scripts/preflight.sh` prints the coverage.
- Leave **≥ 2 min between the hook and Beat A**: the hook restarts shop-api pods and `rate(...[2m])` needs two scrapes before the alert expression has a usage series (measured: 64 s with a gap, 100 s without). On stage, slides 3–8 are that gap.
- Alertmanager keeps a fired alert in memory; `repeat_interval: 1h` means re-applying the rule within the hour sends **no new webhook**. `make reset` restarts Alertmanager for exactly this reason. Fallbacks: `make demo-fake`, `make demo-submit`.
- OpenCost API from the laptop goes through the UI proxy: `curl 'localhost:30091/model/allocation/compute?window=10m&aggregate=namespace'`.
- Prices: $0.04/core-h, $0.005/GiB-h (values/opencost.yaml). shop at baseline ≈ **$186/mo**, after rightsizing ≈ **$5/mo** (3 × 50m / 64Mi).
- **Before going on stage, open every tab once in the browser you will present from**: log in to Argo CD (admin / finops-demo-2026) and dismiss the Argo Workflows UI first-visit survey modal ("Tell us what you want to use Argo for"). Both remember it per browser profile.
- `BOOKMARKS.md` has the tab order and pre-encoded Prometheus graph URLs. `scripts/preflight.sh` is the 10-minutes-before check.

## Offline notes

- Rehearse offline without touching the laptop's Wi-Fi: `make netcut-on` inserts iptables **and ip6tables** rules on the kind node that reject every new outbound connection except cluster/docker subnets; `make netcut-probe` proves it (an uncached `crictl pull` must fail). Docker Desktop gives the node a routable IPv6 default route, so a v4-only cut is silently bypassed. `make netcut-off` removes the rules; a Docker restart also clears them.

- **If Docker Desktop was reset or updated, the image cache is gone**: `make pull` (network) before `make up`. `scripts/preflight.sh` now fails if any demo image is missing on the kind node, and notes if the host cache is incomplete.
- Argo CD and Argo Events manifests default to `imagePullPolicy: Always`; `up.sh` rewrites them and sets `IMAGE_PULL_POLICY=IfNotPresent` on the Events controller.
- Never use digest-pinned image refs (`@sha256:`); `kind load` rewrites digests. OpenCost values override the chart default.
- Gitea runs with `OFFLINE_MODE`, no gravatar, no update checker. Docker Desktop: Resource Saver off; run `caffeinate -dims` during the talk.
