# 2026-11-05: calico-node crash loop on zangetsu (incompatible nftables rules)

- Status: resolved
- Severity: medium (one of two nodes had no working pod network; lab cluster only)
- Found during: step 1.9 (Calico install)

## Summary

After installing Calico in its default iptables data plane, calico-node on zangetsu never became ready. Felix panicked on every start because the iptables inside the calico-node image could not read the `ip nat` table. Tailscale runs on zangetsu as a subnet router in forced nftables mode and adds native nftables rules to that same table. The fix was to move kube-proxy and Calico to the nftables data plane (ADR 0011), then remove the orphan iptables chains kube-proxy left behind.

## Timeline (2026-11-05, UTC-3)

| Time | Event |
|---|---|
| 15:33 | Tigera operator and Installation created. urahara converges; zangetsu's calico-node stays `0/1`. |
| 15:35 | `tigerastatus`: `calico` stays `PROGRESSING`. |
| 15:37 | First look: startup probe fails with `felix is not ready` and `BIRD is not ready`. BGP is established, so the network between nodes is fine. |
| 15:40 | Felix log: `iptables-nft-save failed because there are incompatible nft rules in the table nat`, then `PANIC`. Pod restarted by kubelet (startup probe). |
| 15:45 | `nft list table ip nat` on zangetsu shows a `ts-postrouting` chain. Tailscale log: `TS_DEBUG_FIREWALL_MODE="nftables"`, `firewallmode="nft-forced"`. |
| 15:51 | The Tailscale compose file explains why: the Raspberry Pi kernel has no legacy `ip_tables`, and without nftables mode the subnet router breaks. |
| 15:52 | Confirmed: inside the Tailscale container, `iptables v1.8.11 (legacy)` cannot open the `nat` table. Tailscale in iptables mode is not an option. |
| 15:55 | Decision: nftables data plane for kube-proxy and Calico (ADR 0011). |
| 15:58 | kube-proxy ConfigMap set to `mode: nftables` and restarted; Installation patched to `linuxDataplane: Nftables`. Felix reloads in place. |
| 16:02 | `table ip calico` and `table ip kube-proxy` exist. No more Felix errors. |
| 16:28 | Orphan kube-proxy iptables chains removed on zangetsu. Cluster healthy. |

## Impact

- zangetsu had no working pod network for about 25 minutes (15:33 to 15:58). calico-node restarted 4 times.
- `kubectl get nodes` showed zangetsu `Ready` the whole time, because kubelet was healthy. Node `Ready` did not mean the pod network worked.
- No homelab service was affected: Tailscale, Docker and the subnet router kept working.

## Root cause

Two programs shared the `ip nat` table with different tools:

- Tailscale writes native nftables rules there (forced nftables mode, because the kernel has no legacy `ip_tables`).
- Calico's Felix, in iptables mode, reads the whole table with the `iptables-nft-save` binary shipped in its image. That binary cannot parse Tailscale's rules, so Felix cannot load the table and panics.

The host's own `iptables-nft` could read the table at first, which made the problem look like a Calico bug at first sight.

## What fixed it

1. kube-proxy in nftables mode, then Calico with `linuxDataplane: Nftables`. Both now use their own nftables tables (`ip kube-proxy`, `ip calico`) and no longer read `ip nat` with iptables.
2. Orphan kube-proxy chains (`KUBE-SVC-*`, `KUBE-SEP-*`, `KUBE-NODEPORTS`, `KUBE-SERVICES` and others) removed with `nft flush chain` and `nft delete chain`, after checking that no base chain jumped to them. kubelet's `KUBE-FIREWALL`, `KUBE-KUBELET-CANARY` and `KUBE-IPTABLES-HINT` were kept.

## Lessons

- A node is not only Kubernetes. Agents already on the host (Tailscale, Docker) shape what the CNI can do.
- `Ready` on a node is a kubelet signal, not a network signal. Check calico-node and pod-to-pod traffic too.
- Reading the rules from the host is not enough: the binary inside the container can be a different version with different limits.
- kube-proxy only cleaned its old iptables rules on urahara. On zangetsu the cleanup failed silently for the same reason (it could not read `ip nat`), so the leftovers had to be removed by hand.
- Search logs with a time window that starts after the change, or old errors look like new ones.

## Actions

| Action | Where | Status |
|---|---|---|
| Switch kube-proxy and Calico to nftables | cluster, ADR 0011 | done |
| Remove orphan kube-proxy iptables chains on zangetsu | zangetsu | done |
| Before installing a CNI, list every agent that writes netfilter rules on each node (`nft list tables`) | lab checklist, private environment notes | done |
| Smoke test after any CNI change: DNS and pod-to-pod traffic across nodes, not only `kubectl get nodes` | step 1.11 | open |
| Alert on calico-node restarts and on `tigerastatus` not available | step 2 | open |
