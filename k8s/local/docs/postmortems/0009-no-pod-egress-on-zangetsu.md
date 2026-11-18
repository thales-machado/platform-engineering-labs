# PM-0009: pods on one node lost internet egress for ten hours

- Date: 2026-11-17
- Severity: medium (no user impact, certificate renewal at risk)
- Status: fixed 2026-11-18, verified across a reboot

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

## The planned fix is not available, 2026-11-18

`bpf.masquerade` needs kube-proxy replacement, and kube-proxy replacement needs
BTF, which zangetsu's kernel does not have. PM-0012 has the detail. So the fix
named below cannot happen on this hardware.

What the attempt did reveal is that the current state is more stable than it
looked. The six `CILIUM_*` chains that Cilium managed to write into zangetsu's
`nat` table during a brief window on 2026-11-17 survived four agent restarts
that day and the next. Cilium cannot read that table, so it never removes them
either. Egress on that node works, and keeps working, until the node reboots.

That is still not a fix. It is an unmanaged rule set that no configuration
describes and that disappears on reboot without warning.

Three paths remain, in order of preference:

1. **Write the masquerade rule ourselves, in nftables.** `nft` works on that
   host; only `iptables` does not. A rule for `10.245.0.0/16`, installed by a
   systemd unit so it survives reboots, with Cilium's own masquerading left
   enabled but no longer load-bearing. Ugly, honest, and under configuration
   management.
2. **Give zangetsu a kernel with BTF.** That also unlocks kube-proxy
   replacement and eBPF host routing. It is a change to the homelab's base
   system, not to the lab.
3. **Leave the pin.** cert-manager stays on urahara and the constraint is
   documented. Cheapest, and it fails the next time any workload needs egress.

## Fixed, 2026-11-18

Option 1 from the list above: the masquerade rule is written by hand in
nftables, in its own table, installed by a systemd unit on zangetsu.

`homelab/scripts/networking/k8s-pod-masquerade.sh`:

```
table ip k8s-pod-masq {
    chain postrouting {
        type nat hook postrouting priority srcnat + 10; policy accept;
        ip saddr 10.245.0.0/16 ip daddr != 10.245.0.0/16 oifname "eth0" masquerade
    }
}
```

It uses its own table, so it never touches `ip nat`, which `iptables-nft`
manages and cannot read on that host. Priority `srcnat + 10` puts it after the
normal nat table, so if Cilium ever installs its own rules again they win and
this one becomes dead weight rather than a conflict.

Verified by rebooting zangetsu, which is the only test that counts, because
the state before this change depended on chains that a reboot destroys:

| check | result |
| --- | --- |
| `uptime` | up 4 minutes, a real reboot |
| the unit | `active (exited)`, PID 941, started at boot by systemd |
| `CILIUM` chains in `ip nat` | **0**, the accidental ones are gone |
| our rule's counter | **5 packets**, it is carrying the traffic |
| pod on zangetsu to Let's Encrypt | `egress ok` |

The `nodeSelector` pinning cert-manager to urahara is removed in the same
commit. It existed only for this.

The scheduler then put all three cert-manager pods on zangetsu, and both
ClusterIssuers stayed `Ready`. The one workload in this lab that needs the
internet is running on the node that had none, and reaching Let's Encrypt from
it. That is a better closing test than any probe.

## What this cost to learn

Two days, and a path that went the wrong way twice. `bpf.masquerade` was the
correct answer and needed kube-proxy replacement, which needed BTF, which this
kernel does not have (PM-0012). The answer that worked was the unglamorous
one: write the rule yourself, in the tool that works on that host, and put it
under configuration management so the next reboot does not take it away.

## Action items

- [ ] Probe pod-to-internet egress from every node, and alert on it.
- [ ] kube-proxy replacement plus `bpf.masquerade`, then remove the
      `nodeSelector` added here.
- [ ] Record in the homelab CONVENTIONS.md Tailscale entry that the nftables
      override constrains anything on that host which needs iptables.
