# ADR 0020: replace kube-proxy with Cilium, and masquerade in eBPF

- Date: 2026-11-18
- Status: rejected 2026-11-18, same day it was attempted. See PM-0012.
- Supersedes nothing. Continues ADR 0019.

## Why this was rejected

Tried on 2026-11-18 at 11:03, reverted at 11:34.

`kubeProxyReplacement` loads Cilium's socket load balancer, which needs CO-RE
relocations, which need BTF in the kernel. zangetsu runs the Raspberry Pi
vendor kernel and it has none, so the agent there never initialised its
datapath and no new pod could get an endpoint on that node.

The decision below is sound for hardware whose kernels carry BTF. It is not
available here, and the test that would have caught it in one second is
`ls /sys/kernel/btf/vmlinux` on each node.

Everything that follows is kept as written, because the reasoning is still
the reasoning, and because the next person to want this needs to know it was
tried.

## Context

ADR 0019 moved the cluster to Cilium and left kube-proxy in place on purpose,
as a separate change with its own failure mode. That change is now needed, not
optional, because of PM-0009.

Cilium masquerades pod traffic with iptables. On zangetsu it cannot: tailscaled
writes native nftables rules there, forced by the homelab because the
Raspberry Pi kernel has no legacy `ip_tables`, and `iptables-nft` refuses any
table holding them. Three of the four tables are unreadable, so Cilium installs
no masquerade rules and pods on that node have no route to the internet.

The workaround is a `nodeSelector` pinning cert-manager to urahara. It works
and it is a lie: the node is still broken, and the next workload that needs
egress will find it.

`bpf.masquerade` moves masquerading into eBPF and takes iptables out of that
path. It depends on the BPF NodePort feature, which means kube-proxy
replacement. The two changes are therefore one change.

## Decision

Replace kube-proxy with Cilium's eBPF service handling, then enable
`bpf.masquerade`, in that order, as two separate Helm upgrades.

```yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.15.215
k8sServicePort: 6443
bpf:
  masquerade: true          # second upgrade only
  hostLegacyRouting: true   # unchanged, see below
```

`k8sServiceHost` and `k8sServicePort` are required: without kube-proxy there is
no iptables rule for the `kubernetes` Service, so the agents need the API
server's real address.

## Why two upgrades and not one

Upstream documents that BPF masquerading while kube-proxy is still running
breaks ClusterIP access from remote hosts. Enabling both in one step means a
window where both are true.

So: first `kubeProxyReplacement: true`, remove kube-proxy, clean its rules,
verify. Then `bpf.masquerade: true` as its own change with its own
verification. If something breaks, the two possible causes are already
separated.

## What stays unchanged

`bpf.hostLegacyRouting: true` stays. eBPF host routing is a third change, it
interrupts each node briefly, and nothing here needs it. It is also what made
the mixed-CNI state work in ADR 0019, so changing it in the same window would
muddy any failure.

MetalLB keeps the `192.168.15.241-247` pool and keeps announcing. Cilium's own
L2 announcements are a later phase. MetalLB puts the address on a node; what
changes is that the service lookup after that is eBPF instead of iptables.

## Risks

**zangetsu runs the house's DNS.** Pi-hole serves the LAN from that node, in
Docker, on port 53. Upstream has a documented case of BPF masquerading
interacting with Docker's iptables rules and breaking DNS resolution. Their
case is Docker-in-Docker test clusters, not this shape, but the ingredients
are the same and this host is the one with the crowded netfilter tables.

Mitigation: keepalived holds the Pi-hole VIP and urahara runs the replica, so
DNS survives zangetsu. The runbook tests resolution from a LAN device before
and after, and the rollback does not depend on DNS.

**Cleaning kube-proxy's rules on zangetsu.** The documented cleanup is
`iptables-save | grep -v KUBE | iptables-restore`, and `iptables-save` is
exactly what fails on that node. The runbook reboots zangetsu instead, which
clears every non-persistent nftables rule, and lets tailscaled, Docker and
Cilium write theirs again from scratch.

**One control plane.** `k8sServiceHost` points at urahara. If urahara is down,
the agents cannot reach the API server. That is already true today, and
kube-proxy did not change it, but it is written down here because it is now
explicit in the configuration.

## Rollback

Per node, before the final upgrade: `helm upgrade` back to
`kubeProxyReplacement: false` and restore kube-proxy with
`kubeadm init phase addon kube-proxy` on urahara. kube-proxy is a DaemonSet
and comes back on both nodes on its own.

The ConfigMap deletion is the one step that is not a simple undo: `kubeadm`
recreates it from the cluster configuration with that same command.

## Consequences

Service lookups move from iptables chains to eBPF maps, which is faster and
easier to read with `cilium-dbg bpf lb list` than with `iptables-save`.
Masquerading stops depending on a table that a third tool can make unreadable,
which closes PM-0009 and removes the cert-manager pin.

The cluster also stops being able to explain a networking problem with
`iptables -t nat -L`. Everything moves to `cilium-dbg` and Hubble, which is the
point and also a new thing to learn before the next incident, not during it.
