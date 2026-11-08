.PHONY: pull up down reset urls demo-hook demo-arm demo-rule demo-fake demo-submit demo-block demo-approve demo-ttl status netcut-on netcut-off netcut-probe

pull:            ## pull every image locally (needs network, once)
	./scripts/pull-images.sh

up:              ## create the kind cluster and install everything (offline after `make pull`)
	./scripts/up.sh

down:            ## delete the cluster (images stay in Docker)
	kind delete cluster --name finops

reset:           ## back to the starting state in < 60s
	./scripts/reset.sh

urls:
	@printf 'Argo CD       http://localhost:30080  (admin / finops-demo-2026)\nArgo Workflows http://localhost:30746\nGitea         http://localhost:30300  (finops / finops-demo-2026)\nPrometheus    http://localhost:30090\nAlertmanager  http://localhost:30093\nOpenCost      http://localhost:30091\n'

status:
	@kubectl get pods -A --no-headers | awk '$$4 != "Running" && $$4 != "Completed"' || true
	@kubectl -n argocd get app
	@kubectl -n argo get wf 2>/dev/null || true

netcut-on:       ## simulate dead conference Wi-Fi: reject new outbound connections from the kind node and pods (v4+v6)
	./scripts/netcut.sh on
netcut-off:
	./scripts/netcut.sh off
netcut-probe:    ## prove it: uncached image pull must fail, in-cluster and laptop->NodePort must work
	./scripts/netcut.sh probe

# --- demo beats -------------------------------------------------------------

demo-hook:       ## Beat 0: patch the cluster directly and watch Argo CD selfHeal revert it
	kubectl -n shop set resources deploy/shop-api --requests=cpu=50m
	@echo "watch: kubectl -n shop get deploy shop-api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' -w"

demo-arm:        ## Beat A trigger 1: opt the namespace into the cost guardrail (alert -> Alertmanager -> Argo Events -> Workflow in ~50-65s)
	kubectl label ns shop finops-guard=on
demo-rule: demo-arm

demo-fake:       ## Beat A trigger 2: POST a fake Alertmanager payload straight to the EventSource
	curl -s -X POST http://localhost:30120/alerts -H 'Content-Type: application/json' -d @scripts/fake-alert.json; echo

demo-submit:     ## Beat A trigger 3: submit the workflow directly (skips Events)
	argo -n argo submit --from wftmpl/rightsize -p namespace=shop -p workload=shop-api -p fingerprint=cli --watch

demo-approve:    ## Beat B from the CLI (the UI dropdown is the intended path)
	argo -n argo node set @latest --output-parameter approve=YES --node-field-selector displayName=approve
	argo -n argo resume @latest

demo-block:      ## Beat C: same template against a frozen namespace -> policy blocks -> onExit opens an issue
	argo -n argo submit --from wftmpl/rightsize -p namespace=payments -p workload=payments-api -p fingerprint=cli --watch || true

demo-ttl:        ## Beat D: show the TTL sweeper's recent runs
	argo -n argo cron list
	argo -n argo list -l workflows.argoproj.io/cron-workflow=preview-ttl
	kubectl get ns -l preview=true -o custom-columns='NAME:.metadata.name,EXPIRES:.metadata.annotations.finops\/expires-at,STATUS:.status.phase'
