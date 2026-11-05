# 0012. Accept pod traffic in Docker's DOCKER-USER chain

- Status: accepted
- Date: 2026-11-05
- Follows: ADR 0011 (nftables data plane)

## Context

After the switch to nftables (ADR 0011), the smoke test failed: 100% packet loss between pods on different nodes, and DNS from zangetsu to CoreDNS on urahara timed out.

Docker sets the `FORWARD` chain of `ip filter` to `policy drop` when it enables IP forwarding itself at start. It did that on urahara. On zangetsu, forwarding was already enabled before Docker started, so the policy stayed `accept`.

In iptables mode, Calico adds its ACCEPT rules inside that same `FORWARD` chain, so pod traffic passes. In nftables mode, Calico uses its own table (`ip calico`). In nftables, a packet must be accepted by every base chain on the same hook, so Calico accepting it does not stop Docker's `FORWARD` from dropping it.

Test: two rules in `DOCKER-USER` accepting `10.244.0.0/16` as source and destination on urahara fixed ping and DNS at once.

## Options

- **`"ip-forward-no-drop": true` in Docker's daemon.json**: Docker no longer sets `policy drop`. Simple, but the host then forwards any traffic, not only pod traffic.
- **Rely on boot order**: `/etc/sysctl.d/99-k8s.conf` enables forwarding early, so Docker may not set `drop` after the next reboot. Not reliable, and the security posture would depend on timing.
- **ACCEPT rules for the pod CIDR in `DOCKER-USER`**, re-applied by a systemd unit every time Docker starts. This is the place Docker documents for user rules.

## Decision

Accept only the pod CIDR in `DOCKER-USER`, on both nodes, with an idempotent script and a systemd unit tied to `docker.service`. The `FORWARD` policy stays `drop` where Docker sets it.

## Consequences

- Both nodes behave the same, whatever the boot order.
- The unit runs again when Docker restarts (`PartOf=docker.service`), so the rules come back if Docker recreates its chains.
- The pod CIDR is hard-coded. Step 5 (Cilium, `10.245.0.0/16`) must add the new CIDR during the migration and remove the old one after it.
- Docker's other filtering is unchanged.
