#!/usr/bin/env bash
# Simulate "conference Wi-Fi is dead" without touching the Mac's network: reject every NEW outbound connection
# from the kind node (containerd pulls, kubelet) and from pods (FORWARD) unless it stays inside the cluster /
# docker subnets. Inbound from the laptop to NodePorts and all established flows keep working.
set -euo pipefail
NODE=finops-control-plane
CHAIN=FINOPS_NETCUT
ipt() { docker exec "$NODE" iptables "$@"; }
ip6() { docker exec "$NODE" ip6tables "$@"; }
case "${1:-status}" in
  on)
    ipt -N $CHAIN 2>/dev/null || ipt -F $CHAIN
    ipt -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ipt -A $CHAIN -o lo -j ACCEPT
    ipt -A $CHAIN -d 10.0.0.0/8 -j ACCEPT        # pods + services
    ipt -A $CHAIN -d 172.16.0.0/12 -j ACCEPT     # docker/kind network (incl. the bridge gateway the laptop comes from)
    ipt -A $CHAIN -d 127.0.0.0/8 -j ACCEPT
    ipt -A $CHAIN -j REJECT --reject-with icmp-net-unreachable
    ipt -C OUTPUT  -j $CHAIN 2>/dev/null || ipt -I OUTPUT  1 -j $CHAIN
    ipt -C FORWARD -j $CHAIN 2>/dev/null || ipt -I FORWARD 1 -j $CHAIN
    # Docker Desktop gives the node a routable IPv6 default route: registries are reachable over v6 unless cut too
    ip6 -N $CHAIN 2>/dev/null || ip6 -F $CHAIN
    ip6 -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6 -A $CHAIN -o lo -j ACCEPT
    ip6 -A $CHAIN -d fe80::/10 -j ACCEPT
    ip6 -A $CHAIN -d fc00::/7 -j ACCEPT        # docker ULA network
    ip6 -A $CHAIN -d ::1/128 -j ACCEPT
    ip6 -A $CHAIN -j REJECT --reject-with icmp6-adm-prohibited
    ip6 -C OUTPUT  -j $CHAIN 2>/dev/null || ip6 -I OUTPUT  1 -j $CHAIN
    ip6 -C FORWARD -j $CHAIN 2>/dev/null || ip6 -I FORWARD 1 -j $CHAIN
    echo "netcut ON: node + pods cannot open connections outside the cluster (v4 + v6)"
    ;;
  off)
    ipt -D OUTPUT  -j $CHAIN 2>/dev/null || true
    ipt -D FORWARD -j $CHAIN 2>/dev/null || true
    ipt -F $CHAIN 2>/dev/null || true; ipt -X $CHAIN 2>/dev/null || true
    ip6 -D OUTPUT  -j $CHAIN 2>/dev/null || true
    ip6 -D FORWARD -j $CHAIN 2>/dev/null || true
    ip6 -F $CHAIN 2>/dev/null || true; ip6 -X $CHAIN 2>/dev/null || true
    echo "netcut OFF"
    ;;
  status)
    if ipt -C OUTPUT -j $CHAIN 2>/dev/null; then echo "netcut ON (v4$(ip6 -C OUTPUT -j $CHAIN 2>/dev/null && echo +v6))"; ipt -L $CHAIN -n -v | tail -n +3; ip6 -L $CHAIN -n -v 2>/dev/null | tail -n +3; else echo "netcut OFF"; fi
    ;;
  probe)
    printf 'node image pull (uncached): '; docker exec "$NODE" timeout 20 crictl pull docker.io/library/busybox:1.37.0 >/dev/null 2>&1 && echo "SUCCEEDED (bad: egress open)" || echo "failed (good)"
    printf 'node -> 1.1.1.1:443      : '; docker exec "$NODE" timeout 6 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && echo "OPEN (bad)" || echo "blocked"
    printf 'pod  -> 1.1.1.1:443      : '; kubectl -n argo run netprobe --rm -i --restart=Never --image=alpine/k8s:1.36.6 --image-pull-policy=IfNotPresent --command -- sh -c 'curl -s -m 6 -o /dev/null -w "%{http_code}" https://1.1.1.1/ && echo " OPEN (bad)" || echo "blocked"' 2>/dev/null | grep -v '^pod ' || echo "blocked"
    printf 'pod  -> gitea-http.gitea : '; kubectl -n argo run netprobe2 --rm -i --restart=Never --image=alpine/k8s:1.36.6 --image-pull-policy=IfNotPresent --command -- sh -c 'curl -s -m 6 -o /dev/null -w "%{http_code}\n" http://gitea-http.gitea.svc:3000/api/v1/version' 2>/dev/null | grep -v '^pod ' || echo "FAIL"
    printf 'laptop -> argo cd :30080 : '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://localhost:30080
    ;;
  *) echo "usage: $0 on|off|status|probe"; exit 2;;
esac
