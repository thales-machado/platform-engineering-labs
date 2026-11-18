# Runbook: kube-proxy replacement and eBPF masquerading

ADR 0020. Run the phases in order. Stop at the first check that does not match.

Total disruption expected: two node reboots, one of them the control plane.
Pi-hole on zangetsu goes down during its reboot; keepalived moves the VIP to
urahara. Do this when nobody needs the house's DNS to be fast.

## Phase 0: before anything

```bash
kubectl get node -o wide
kubectl get pod -A -o wide | grep -vE 'Running|Completed'
kubectl -n argocd get app | grep -v Healthy
kubectl -n lab-db get cluster lab-pg

# etcd snapshot, same as ADR 0019 phase 0
sudo cp /var/lib/etcd/member/snap/db /var/lib/etcd/snapshot-pre-kpr.db 2>/dev/null \
  || kubectl -n kube-system exec etcd-urahara -- etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save /var/lib/etcd/snapshot-pre-kpr.db
```

Record what "working" looks like, so the comparison afterwards is not from
memory:

```bash
kubectl get pod -A -o wide | sort > /tmp/pods-before-kpr.txt
for h in app grafana prometheus argocd dashboard rollouts; do
  printf "%-11s " $h; curl -sk -o /dev/null -w '%{http_code}\n' "https://$h.lab.thalespm.me/"
done
# DNS for the house, from a LAN device that is not a cluster node
dig +short lan.thalespm.me @192.168.15.248 | head -2
```

Pause Argo on Cilium so it cannot fight the Helm upgrades:

```bash
kubectl -n argocd patch app cilium --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null \
  || echo "cilium is not an Argo Application, nothing to pause"
```

## Phase 1: Cilium takes over services, kube-proxy still installed

Edit `components/cilium/values.yaml`:

```yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.15.215
k8sServicePort: 6443
```

Leave `bpf.masquerade` out of this phase.

```bash
helm upgrade cilium cilium/cilium -n kube-system --version 1.20.4 \
  -f k8s/local/components/cilium/values.yaml
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i kubeproxy
```

Expect `KubeProxyReplacement: True`. Both kube-proxy and Cilium now program
service traffic; that overlap is intended and brief.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list | head -15
curl -sk -o /dev/null -w 'app %{http_code}\n' https://app.lab.thalespm.me/
```

Services must still answer. If they do not, roll back here: set
`kubeProxyReplacement: false`, `helm upgrade`, done. kube-proxy never left.

## Phase 2: remove kube-proxy

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
```

The ConfigMap goes too, or a future `kubeadm upgrade` reinstalls kube-proxy.

Now clean its rules.

**This cluster runs kube-proxy in nftables mode**, not iptables. Its rules are
not in the `KUBE-*` chains the upstream docs talk about; they are in two tables
of their own. The documented cleanup,
`iptables-save | grep -v KUBE | iptables-restore`, removes nothing here and
reports success, which is worse than failing.

Same two commands on both nodes, and `nft` works on zangetsu even though
`iptables` does not:

```bash
sudo nft list tables | grep kube-proxy
sudo nft delete table ip kube-proxy
sudo nft delete table ip6 kube-proxy
sudo nft list tables | grep -c kube-proxy      # expect 0
```

Calico also leaves its VXLAN interface behind until a reboot, and Cilium
attaches its programs to it. Remove it on both nodes:

```bash
ip -brief link show | grep -E 'cilium|vxlan|cali'
sudo ip link delete vxlan.calico
```

No drain and no reboot are needed for any of this. An earlier version of this
runbook rebooted zangetsu to clear the rules, on the assumption that they were
iptables rules that could not be read there. They are nftables rules and `nft`
deletes them in place, so the Pi-hole failover this step used to require never
happens.

Verify services still work with no kube-proxy anywhere:

```bash
for h in app grafana prometheus argocd dashboard rollouts; do
  printf "%-11s " $h; curl -sk -o /dev/null -w '%{http_code}\n' "https://$h.lab.thalespm.me/"
done
kubectl run svc-test --image=nginx:alpine --restart=Never -- sleep 120
sleep 12
kubectl exec svc-test -- wget -qO- --timeout=5 https://kubernetes.default.svc/healthz --no-check-certificate; echo
kubectl delete pod svc-test
```

Stop here if anything fails. Rollback: `kubeadm init phase addon kube-proxy`
on urahara, then `kubeProxyReplacement: false` and `helm upgrade`.

## Phase 3: masquerade in eBPF

This is the phase PM-0009 needs. Add to `values.yaml`:

```yaml
bpf:
  masquerade: true
  hostLegacyRouting: true
```

```bash
helm upgrade cilium cilium/cilium -n kube-system --version 1.20.4 \
  -f k8s/local/components/cilium/values.yaml
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i masquerad
```

Expect `Masquerading: BPF`, not `IPTables`.

The test that this was all for:

```bash
kubectl run eg-z --image=nginx:alpine --restart=Never \
  --overrides='{"spec":{"nodeName":"zangetsu","tolerations":[{"operator":"Exists"}]}}' -- sleep 180
sleep 15
kubectl exec eg-z -- wget -qO- --timeout=8 https://acme-v02.api.letsencrypt.org/directory >/dev/null \
  && echo "zangetsu egress ok" || echo "zangetsu egress FAIL"
kubectl delete pod eg-z
```

And the risk the ADR names, DNS for the house:

```bash
dig +short lan.thalespm.me @192.168.15.248 | head -2
dig +short google.com @192.168.15.248 | head -2
ssh keydrop@192.168.15.214 'docker logs pi-hole --since 5m 2>&1 | tail -5'
```

If DNS breaks here, roll back phase 3 alone: `bpf.masquerade: false`,
`helm upgrade`. kube-proxy stays gone; only masquerading returns to iptables,
which is where it was yesterday.

## Phase 4: remove the workaround

Only after the egress probe has read 1 for an hour.

```bash
# drop the nodeSelector block from components/cert-manager/values.yaml
git commit && git push
kubectl -n argocd get app cert-manager
kubectl -n cert-manager get pod -o wide
```

cert-manager should spread across both nodes again. Then re-enable Argo on
Cilium, and close PM-0009 with the probe history as evidence.

## What to check at the end

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | head -20
kubectl get pod -A -o wide | sort > /tmp/pods-after-kpr.txt
diff /tmp/pods-before-kpr.txt /tmp/pods-after-kpr.txt | head -40
kubectl -n kube-system get ds                       # no kube-proxy
sudo iptables-save | grep -c KUBE-SVC               # 0 on urahara
```

Then the probes, which now cover what the last two postmortems missed:

```bash
kubectl -n lab-obs port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 4
curl -s --data-urlencode 'query=avg_over_time(probe_success[15m])' http://localhost:9090/api/v1/query > /tmp/p.json
kill %1
python3 - <<'PY'
import json
for r in json.load(open('/tmp/p.json'))['data']['result']:
    m = r['metric']
    print('%-9s %-45s %s' % (m.get('check','netcheck'),
          m.get('node') or m.get('path') or m.get('instance',''), r['value'][1][:5]))
PY
```

Nine lines at 1, including `egress zangetsu`, is the definition of done.

## Known unknowns

- Cilium still writes some iptables rules with `bpf.masquerade` on. The
  reconciliation errors on zangetsu may continue in the agent log. Whether
  that matters for anything other than masquerading is not established; check
  the log after phase 3 and write down what it says.
- MetalLB L2 with kube-proxy replacement is a common combination and is
  expected to work, but it is not tested here. Phase 2's hostname checks are
  what prove it, since every one of them arrives through the MetalLB address.
- Hubble was enabled on 2026-11-17 and has not been through a node reboot yet.
