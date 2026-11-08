# Browser bookmarks for the talk (open all in one Chrome window, 150% zoom)

Open in this tab order, left to right:

1. **Argo CD app `shop`** — http://localhost:30080/applications/argocd/shop?view=tree  (admin / finops-demo-2026)
2. **Prometheus: shop $ run-rate / month** — http://localhost:30090/graph?g0.expr=sum%28kube_pod_container_resource_requests%7Bnamespace%3D%22shop%22%2Cresource%3D%22cpu%22%7D%29+%2A+scalar%28avg%28node_cpu_hourly_cost%29%29+%2A+730+%2B+sum%28kube_pod_container_resource_requests%7Bnamespace%3D%22shop%22%2Cresource%3D%22memory%22%7D%29+%2F+1073741824+%2A+scalar%28avg%28node_ram_hourly_cost%29%29+%2A+730&g0.tab=0&g0.range_input=30m&g0.step_input=&g0.stacked=0
3. **Prometheus: shop-api CPU requested vs used (cores)** — http://localhost:30090/graph?g0.expr=sum%28kube_pod_container_resource_requests%7Bnamespace%3D%22shop%22%2Ccontainer%3D%22shop-api%22%2Cresource%3D%22cpu%22%7D%29+or+label_replace%28sum%28rate%28container_cpu_usage_seconds_total%7Bnamespace%3D%22shop%22%2Ccontainer%3D%22shop-api%22%7D%5B2m%5D%29%29%2C+%22what%22%2C+%22usage%22%2C+%22%22%2C+%22%22%29&g0.tab=0&g0.range_input=30m&g0.step_input=&g0.stacked=0
4. **Argo Workflows** — http://localhost:30746/workflows/argo
5. **Gitea PRs** — http://localhost:30300/finops/gitops/pulls
6. **Gitea issues** — http://localhost:30300/finops/gitops/issues
7. **Alertmanager** — http://localhost:30093/#/alerts
8. **OpenCost** — http://localhost:30091/?window=15m&aggregateBy=namespace

Extra:
- Prometheus: efficiency ratio — http://localhost:30090/graph?g0.expr=sum%28rate%28container_cpu_usage_seconds_total%7Bnamespace%3D%22shop%22%2Ccontainer%3D%22shop-api%22%7D%5B2m%5D%29%29+%2F+sum%28kube_pod_container_resource_requests%7Bnamespace%3D%22shop%22%2Ccontainer%3D%22shop-api%22%2Cresource%3D%22cpu%22%7D%29&g0.tab=0&g0.range_input=30m&g0.step_input=&g0.stacked=0
- Prometheus: the alert expression itself — http://localhost:30090/graph?g0.expr=%28sum+by+%28namespace%2C+container%29+%28rate%28container_cpu_usage_seconds_total%7Bcontainer%21%3D%22%22%2C+image%21%3D%22%22%2C+namespace%3D~%22shop%7Cpayments%22%7D%5B2m%5D%29%29+%2F+sum+by+%28namespace%2C+container%29+%28kube_pod_container_resource_requests%7Bresource%3D%22cpu%22%7D%29%29&g0.tab=0&g0.range_input=30m&g0.step_input=&g0.stacked=0
- Argo Workflows cron list — http://localhost:30746/cron-workflows/argo
- Sensor YAML on screen: `events/sensor.yaml`; template YAML: `workflows/rightsize.yaml`
