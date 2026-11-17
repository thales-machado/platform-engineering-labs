# Runbook: Calico to Cilium, live

Decision and reasoning: [ADR 0019](../adr/0019-calico-to-cilium.md).

Read this whole file before running the first command. The dangerous moment is
not the migration, it is improvising halfway through it.

## Before anything

```bash
# 1. etcd snapshot, kept on the host
kubectl -n kube-system exec etcd-urahara -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-pre-cilium.db
sudo sh -c 'ls -lh /var/lib/etcd/snapshot-pre-cilium.db'

# 2. prove it opens, do not assume
kubectl apply -f drills/etcd-restore-check.yaml
sleep 75 && kubectl -n kube-system logs etcd-restore-check -c status
kubectl -n kube-system delete pod etcd-restore-check

# 3. record the state we expect to get back
kubectl get nodes -o wide
kubectl get pods -A -o wide > /tmp/pods-before-cilium.txt
kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
kubectl -n lab-db get cluster lab-pg -o jsonpath='{.status.phase} {.status.readyInstances}/{.status.instances}{"\n"}'
for h in app grafana dashboard argocd rollouts; do
  curl -sk -o /dev/null -w "$h %{http_code}\n" https://$h.lab.thalespm.me/ ; done

# 4. stop Argo CD from fighting the migration
for a in $(kubectl -n argocd get app -o name); do
  kubectl -n argocd patch $a --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
kubectl -n argocd get app -o custom-columns='NAME:.metadata.name,AUTO:.spec.syncPolicy.automated'
```

Step 4 is not optional. `calico` is an Application with `selfHeal: true`, and a
controller that reverts changes during a CNI migration will undo exactly the
thing you are in the middle of.

## Phase 1: Cilium alongside Calico

Values in [components/cilium/values-migration.yaml](../../components/cilium/values-migration.yaml).

```bash
helm repo add cilium https://helm.cilium.io
helm repo update cilium
helm install cilium cilium/cilium --version 1.20.4 \
  -n kube-system -f components/cilium/values-migration.yaml

kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

Expected: Cilium pods Running on both nodes, and **zero pods managed by
Cilium**. Nothing has changed about the network yet. If any pod has moved to
the new CIDR at this point, stop: `cni.customConf` is not doing its job.

Then the per-node config, which starts matching no nodes:

```bash
kubectl apply --server-side -f components/cilium/node-config.yaml
kubectl -n kube-system get ciliumnodeconfig
```

## Phase 2: zangetsu

The cheap node first. It runs DaemonSets, one `lab-app` replica, one netcheck
target and the Postgres replica.

```bash
NODE=zangetsu
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=10m

kubectl label node $NODE --overwrite io.cilium.migration/cilium-default=true
kubectl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE
kubectl -n kube-system rollout status ds/cilium

ssh keydrop@192.168.15.214 'ls -l /etc/cni/net.d/'
```

`05-cilium.conflist` must be there before the reboot. Calico's config is not
deleted, it is renamed: zangetsu showed `10-calico.conflist.cilium_bak`
alongside the new file. That is better than this runbook first assumed, because
rollback after the reboot is one `mv` and a kubelet restart.

The kubelet reads the lowest-numbered conflist, so `05-cilium` wins while the
Calico file keeps its contents. That rename is the point of no return for the
node in practice, since the next pod to start gets a Cilium IP.

```bash
ssh keydrop@192.168.15.214 sudo reboot
# wait for it to come back
kubectl get node $NODE -o wide
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | head -20
```

Validate before uncordoning:

```bash
kubectl run cilium-test --image=nginx:alpine --restart=Never \
  --overrides='{"spec":{"nodeName":"zangetsu","tolerations":[{"operator":"Exists"}]}}'
kubectl get pod cilium-test -o jsonpath='{.status.podIP}{"\n"}'   # expect 10.245.x.x
kubectl exec cilium-test -- wget -qO- --timeout=5 https://kubernetes.default.svc/healthz --no-check-certificate || true
kubectl delete pod cilium-test
kubectl uncordon $NODE
```

A pod IP in `10.245.0.0/16` is the proof that Cilium owns this node.

**Rollback, only before the reboot:** remove the label, delete the Cilium pod
on that node, confirm Calico's conflist is still present, uncordon. After the
reboot, rollback means putting Calico's CNI config back by hand.

## Phase 3: urahara

Same procedure, far more at stake: the control plane, Argo CD, Prometheus,
Grafana, Loki and the Postgres primary, all with node-bound volumes.

```bash
# move the database first, so the reboot is not also a failover
kubectl cnpg promote lab-pg -n lab-db lab-pg-2
kubectl cnpg status lab-pg -n lab-db | head -12
```

Then the same commands as zangetsu with `NODE=urahara` and `192.168.15.215`.
Expect `kubectl` to fail while the node reboots: the API server is on it. That
is not a failure, it is the cost named in ADR 0019.

Two differences from zangetsu:

- The static pods (`etcd`, `kube-apiserver`, `kube-controller-manager`,
  `kube-scheduler`) are not evicted by a drain, so `kubectl` keeps working
  between the drain and the reboot.
- Every PVC on `local-path` is pinned to urahara by node affinity: Prometheus,
  Loki, Grafana, Argo CD's repo cache and `lab-pg-1`. The drain evicts those
  pods and they stay `Pending` until the node is back and uncordoned. Nothing
  is lost, the data is on the disk that is rebooting, but the lab is blind for
  the duration: no dashboards, no in-cluster alerts, no Argo.

The homelab alerting is the only part of the stack that survives this reboot.
Leave it on. Watching it fire during a planned outage is free evidence that it
would fire during an unplanned one.

While it is down, nothing in the lab answers. The homelab alerting will fire,
which is correct and worth leaving on: it is the only part of the stack that
survives this reboot, and seeing it work during a planned outage is free
evidence that it would work during an unplanned one.

## Phase 4: cleanup

Only once both nodes report Cilium and every pod has an IP in `10.245.0.0/16`.

```bash
kubectl get pods -A -o wide | grep -c '10.244\.'   # must be 0
```

```bash
helm upgrade cilium cilium/cilium --version 1.20.4 \
  -n kube-system -f components/cilium/values.yaml
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system delete ciliumnodeconfig cilium-default
```

Then remove Calico, which is also when its Argo Application and its file go:

```bash
kubectl delete -f components/calico/installation.yaml
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
kubectl get pods -n calico-system -n tigera-operator
```

Re-enable Argo CD last, after the cluster is proven:

```bash
# remove gitops/apps/calico.yaml from the repo first, then
for a in $(kubectl -n argocd get app -o name); do
  kubectl -n argocd patch $a --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'
done
```

## What to check at the end

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -v '10.245\.' | grep -v 'hostNetwork\|Completed'
kubectl -n lab-db get cluster lab-pg
for h in app grafana dashboard argocd rollouts; do
  curl -sk -o /dev/null -w "$h %{http_code}\n" https://$h.lab.thalespm.me/ ; done
kubectl -n lab-obs get pods
diff <(sort /tmp/pods-before-cilium.txt) <(kubectl get pods -A -o wide | sort) | head -40
```

The cross-node probe from PM-0003 is the one that matters most: it is the only
thing in the cluster that proves east-west traffic works, which is exactly what
a CNI migration can break while everything else looks healthy.

## Known unknowns

- Cilium's docs say migration is untested with an existing NetworkPolicy
  provider. Calico is one. This cluster has no NetworkPolicy objects, which is
  why that is survivable here.
- MetalLB and Cilium both do L2. They are not expected to conflict while
  MetalLB owns the pool and Cilium's LB IPAM stays off, and that assumption
  gets tested the moment Traefik's IP has to come back after the urahara
  reboot.
- `local-path` volumes are node-bound. A node that does not come back is a
  database and an observability stack that do not come back either. The etcd
  snapshot does not cover PVC data; Restic in the homelab does.
