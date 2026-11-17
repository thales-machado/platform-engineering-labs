# 0019. Calico to Cilium, live, one node at a time

- Status: accepted
- Date: 2026-11-16

## Context

Step 5 replaces the CNI on a running two-node cluster. Cilium is the CNI the
target roles name, it replaces kube-proxy and can replace MetalLB, and Hubble
gives flow visibility that neither Calico nor the step 2 stack provides.

The cluster is not empty. It runs a Postgres cluster with node-bound volumes,
the observability stack with three PVCs on urahara, Argo CD managing twenty
Applications, and Traefik holding `192.168.15.241`, which is every hostname in
the lab. urahara is both the control plane and the only node with storage.

What exists today: Calico v3.33.0 with VXLAN on port 4789, pod CIDR
`10.244.0.0/16`, kube-proxy in nftables mode, MetalLB in L2 mode.

## Options

- **Rebuild the cluster with Cilium.** Honest, fast, and throws away the thing
  that makes this lab worth anything: four weeks of state, seven postmortems and
  a cluster that has survived real failures. Rejected.
- **Cilium chained over Calico.** Both CNIs permanently, Cilium for policy and
  observability only. Less disruption, but it keeps Calico forever and gets
  neither kube-proxy replacement nor the dataplane.
- **Per-node live migration.** The procedure Cilium documents: install in
  secondary mode, take over one node at a time, remove Calico at the end.

## Decision

Per-node live migration, Cilium 1.20.4, in four phases separated in time:

1. **Migration.** Cilium alongside Calico, zangetsu first, urahara second.
2. **Cleanup.** Calico removed, Cilium promoted to primary, policy enforcement on.
3. **kube-proxy replacement.** A separate change, after the cluster has been stable on Cilium.
4. **MetalLB replaced by Cilium L2 announcements and LB IPAM.** Last, because it moves the IP that serves every route.

Phases 3 and 4 are deliberately not part of the migration. Each is a change
whose failure mode is distinct, and combining them means not knowing which one
broke the cluster.

Settings forced by what is already running:

| Setting | Value | Why |
|---|---|---|
| IPAM | `cluster-pool` | required for migration, prevents collisions with Calico's allocations |
| Pod CIDR | `10.245.0.0/16` | must not overlap `10.244.0.0/16` |
| Tunnel | VXLAN, port 8472 | Calico holds VXLAN 4789; two overlays cannot share an encapsulation port. GENEVE was the first choice and the Raspberry Pi kernel has no geneve module |
| `policyEnforcementMode` | `never` during migration | otherwise traffic from Calico-managed pods is dropped |
| `bpf.hostLegacyRouting` | `true` during migration | so the two dataplanes can route to each other |
| `cni.customConf` | `true` initially | Cilium writes no CNI config until a node is labelled |
| `operator.unmanagedPodWatcher.restart` | `false` | the operator must not restart pods Calico still manages |

Node order is zangetsu then urahara, and not the reverse. zangetsu runs only
DaemonSets and one Postgres replica; urahara runs the control plane, Argo CD,
the whole observability stack and the Postgres primary. Migrating the cheap
node first turns the expensive one into a repeat of a known procedure.

Argo CD is paused for the duration. It manages `calico` with `selfHeal: true`,
and a controller that reverts changes is the opposite of what a migration
needs. The `calico` Application and its file are removed in phase 2, not before.

## Consequences

Each node reboots, so each node's pods move. For zangetsu that costs the
Postgres replica and half of `lab-app`. For urahara it costs the control plane,
Argo CD, Prometheus, Grafana, Loki and the Postgres primary at once, and the
node-bound PVCs mean those pods cannot run elsewhere: they are down until the
node is back.

The SLO will be spent. A reboot of urahara is minutes, not seconds, and the
error budget is 43m12s per 30 days. That is expected and is the first real use
of the budget as something other than a dashboard.

Pod IPs change. Anything that cached one has a bad day, which in this cluster
means the probes in step 2 and the `netcheck` targets, both of which resolve
through Services and should recover on their own. It is worth checking rather
than assuming.

Rollback is per node and only before the reboot: unlabel the node, restart the
Cilium pod, confirm Calico's CNI config is still in `/etc/cni/net.d`. After a
node has rebooted on Cilium with `cni-exclusive: true`, Calico's config file is
gone from that node and rollback means restoring it by hand. The etcd snapshot
does not help here: this is node-local state, not cluster state.

The honest risk: Cilium's own documentation says migration has not been tested
with an existing NetworkPolicy provider, and Calico is one. This cluster has no
NetworkPolicy objects, which is why that warning is survivable here and would
not be in a cluster that had them.

## Correction, same day

The first attempt used GENEVE on 6081, chosen because Calico holds VXLAN 4789.
It failed on zangetsu: kernel 6.18.34+rpt-rpi-2712 ships no geneve module, so
`cilium_geneve` could not be created, the datapath never initialised, and the
kubelet got `429 putEndpointIdTooManyRequests` for every pod on that node.

The reasoning about the port clash was right; the assumption that both kernels
offer the same tunnel protocols was never checked, and one node is an arm64
board with a vendor kernel. VXLAN on 8472 avoids both the clash and the missing
module, and `vxlan.ko` is loaded on both nodes because Calico uses it.

It cost nothing because the node was drained and cordoned first, which is the
entire reason the ADR migrates the cheap node before the control plane.
