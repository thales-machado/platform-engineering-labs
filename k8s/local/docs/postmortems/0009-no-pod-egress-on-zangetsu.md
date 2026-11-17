# PM-0009: pods on one node lost internet egress for ten hours

- Date: 2026-11-17
- Severity: medium (no user impact, certificate renewal at risk)
- Status: mitigated (workaround in place, real fix scheduled)

## Impact

From 23:55 on 2026-11-16, no pod scheduled on zangetsu could reach the
internet. In-cluster traffic, LAN traffic and image pulls were unaffected.

Nothing alerted. It was found at 09:00 the next morning because Argo CD showed
`cert-manager-config` as Degraded, and the reason turned out to be:

```
Failed to register ACME account:
Get "https://acme-v02.api.letsencrypt.org/directory":
dial tcp 172.65.32.248:443: i/o timeout
```

cert-manager is the only workload in this lab that talks to the internet. The
wildcard certificate renews on 2027-01-05. Had this gone unnoticed, the failure
would have surfaced then, as expired TLS on every lab hostname.

## What happened

Phase 3 of the Calico to Cilium migration (ADR 0019) rebooted urahara at 23:57.
cert-manager had been evicted to zangetsu by the drain a few minutes earlier,
and that is where it stayed.

Cilium masquerades with iptables. On zangetsu it could not:

```
iptables rules full reconciliation failed, will retry another one later
error="failed to remove old backup rules: unable to run 'iptables -t nat -S'
iptables command: exit status 1
stderr=\"iptables v1.8.8 (nf_tables): table `nat' is incompatible,
use 'nft' tool.\""
```

Without those rules there is no SNAT for pod traffic leaving the node, so
packets go out with a `10.245.x.x` source address and nothing comes back.

Three of the four tables were unreadable: `nat`, `mangle` and `filter`. `raw`
was fine. Every unreadable one contained rules written natively by tailscaled:
`ts-postrouting` in `nat`, `ts-forward` and `ts-input` in `filter`, and a
connmark pair in `mangle`. urahara, whose tables Cilium writes to happily, has
none of them.

## Why zangetsu and not urahara

Both hosts run Tailscale as a containerized subnet router with
`network_mode: host`. zangetsu is a Raspberry Pi 5 whose kernel has no legacy
`ip_tables`, so the homelab forces `TS_DEBUG_FIREWALL_MODE=nftables` there:
with the default iptables backend, tailscaled fails to create its own chains,
SNAT included. That override is documented in the homelab's CONVENTIONS.md and
predates this lab.

So the collision is structural. tailscaled must write native nft rules on that
host, and `iptables-nft` declares any table holding them incompatible, which
stops Cilium from writing its own. Calico never hit this because PM-0002 had
already moved Calico to its nftables dataplane on the same host, for the same
underlying reason.

Deleting the Tailscale chains proves the cause and fixes nothing: removing
`ts-postrouting` made `nat` readable within seconds, and tailscaled rewrites
its rules on every restart.

## The hole in the monitoring

Ten hours. The lab watches:

- pod-to-pod traffic, through the netcheck probes from PM-0003
- one hostname from outside, for the SLO
- control plane, node and container health

None of that touches pod-to-internet egress, so a node can lose it completely
and every dashboard stays green. The same gap as PM-0008, found the same
morning: the lab measures what it thought to measure.

## Mitigation

cert-manager pinned to urahara with a `nodeSelector`, in
`components/cert-manager/values.yaml`, with the reason in a comment. The
certificate is valid to 2027-02-04 and both ClusterIssuers are Ready again.

## The actual fix

`bpf.masquerade: true`, which takes iptables out of Cilium's path entirely.
It depends on the BPF NodePort feature, so it comes with kube-proxy
replacement, already planned as its own phase of step 5. Two things to verify
in that phase, both documented upstream:

- BPF masquerading while kube-proxy is still running breaks ClusterIP access
  from remote hosts, so the switch has to be complete, not partial.
- BPF masquerading has a known interaction with Docker's iptables rules that
  breaks DNS resolution. zangetsu runs the whole homelab Docker stack,
  including DNS on port 53, so this needs testing there specifically.

## Action items

- [ ] Probe pod-to-internet egress from every node, and alert on it.
- [ ] kube-proxy replacement plus `bpf.masquerade`, then remove the
      `nodeSelector` added here.
- [ ] Record in the homelab CONVENTIONS.md Tailscale entry that the nftables
      override constrains anything on that host which needs iptables.
