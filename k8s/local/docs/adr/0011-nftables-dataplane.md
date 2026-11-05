# 0011. nftables data plane for kube-proxy and Calico

- Status: accepted
- Date: 2026-11-05
- Changes: ADR 0004 (Calico still first CNI, now with the nftables data plane)

## Context

After the first install, calico-node on zangetsu never became ready. Felix panicked on every start:

```
iptables-nft-save failed because there are incompatible nft rules in the table nat
```

Tailscale runs on zangetsu as a subnet router, in host network mode, forced into nftables mode (`TS_DEBUG_FIREWALL_MODE=nftables`). It adds its own chains (`ts-postrouting` and others) to the shared `ip nat` table with native nftables rules. The iptables binary inside the calico-node image cannot read those rules, so Felix cannot load the table and panics. The host's `iptables-nft` reads them fine, which hides the problem when checking from the host.

Tailscale cannot move to iptables mode: the Raspberry Pi kernel has no legacy `ip_tables` support, and the iptables inside the Tailscale image is the legacy one (`can't initialize iptables table 'nat': Table does not exist`).

## Options

- **Tailscale in iptables mode**: impossible on this kernel (see above).
- **Tailscale in userspace mode**: no firewall rules at all, but it changes a working subnet router, with a documented fix, and is slower on the Pi.
- **kube-proxy and Calico in nftables mode**: both stop sharing the `ip nat` table with iptables and use their own nftables tables. Calico's nftables data plane requires kube-proxy in nftables mode.

## Decision

Switch the cluster to nftables: kube-proxy `mode: nftables` and Calico `linuxDataplane: Nftables`. Tailscale is not touched.

## Consequences

- The cluster adapts to the agents already on the node, instead of the other way around. Both nodes are nftables-native (Debian 13, kernels 6.12 and 6.18, above the 5.13 minimum).
- Rules are read with `nft list table ...` instead of `iptables -S`. Kubernetes and Calico rules live in their own tables (`ip kube-proxy`, `calico`).
- Leftover iptables rules from the first install must be checked after the switch.
- Step 5 (Cilium, eBPF, kube-proxy replacement) removes kube-proxy anyway; this choice keeps the cluster healthy until then.
