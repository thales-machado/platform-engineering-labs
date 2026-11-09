# PM-0003: Pod traffic between nodes dropped by Docker's FORWARD policy

- ID: PM-0003
- Date: 2026-11-05
- Status: resolved
- Severity: medium (no pod traffic between nodes, no cluster DNS from zangetsu; lab cluster only)
- Found during: step 1.11 (smoke test), right after the nftables switch (ADR 0011)

## Summary

After moving kube-proxy and Calico to nftables, every node was `Ready` and every pod was `Running`, but pods on different nodes could not reach each other and DNS from zangetsu timed out. Docker had set the `FORWARD` chain of `ip filter` to `policy drop` on urahara. In nftables mode Calico writes its rules in its own table, which cannot override another table's drop on the same hook. Two ACCEPT rules for the pod CIDR in `DOCKER-USER` fixed it, and a systemd unit now applies them every time Docker starts (ADR 0012).

## Timeline (2026-11-05, UTC-3)

| Time | Event |
|---|---|
| 16:02 | nftables switch verified: `ip calico` and `ip kube-proxy` tables exist, no Felix errors. |
| 16:32 | Smoke test: one busybox pod per node. Ping 100% loss both ways; `nslookup` from zangetsu: `connection timed out`. |
| 16:33 | Hypothesis: Docker's `FORWARD` policy drop, no longer bypassed by Calico in nftables mode. |
| 16:38 | Confirmed: urahara `policy drop`, zangetsu `policy accept`. Two temporary rules in `DOCKER-USER` on urahara: ping 0% loss, DNS answers. |
| 16:41 | Permanent fix (script and systemd unit on both nodes). Smoke test passes both ways, DNS works. |

## Impact

- No pod-to-pod traffic between the nodes and no cluster DNS from zangetsu, for about 40 minutes after the nftables switch (15:58 to 16:38).
- Every status signal was green: nodes `Ready`, pods `Running`, `tigerastatus` available. Only a real traffic test showed the problem.
- No homelab service was affected.

## Root cause

- Docker sets `FORWARD` to `policy drop` only when it enables IP forwarding itself at start. It did on urahara. On zangetsu forwarding was already enabled before Docker started, so the policy stayed `accept`. The same setup behaved differently on each node because of boot order.
- In iptables mode, Calico inserts ACCEPT rules inside that same `FORWARD` chain, so the drop policy never hit pod traffic. That is why the problem appeared only after ADR 0011.
- In nftables, each table has its own base chains, and a packet must be accepted by every base chain on the hook. Calico accepting in `ip calico` does not stop `ip filter FORWARD` from dropping.

## What fixed it

ACCEPT rules for `10.244.0.0/16` (source and destination) in `DOCKER-USER`, the chain Docker documents for user rules, on both nodes. An idempotent script applies them, and a systemd unit with `PartOf=docker.service` runs it whenever Docker starts. The `drop` policy stays where Docker sets it.

## Lessons

- Green status is not a working network. A smoke test with real traffic (pod to pod across nodes, DNS through a Service) belongs after every CNI or firewall change.
- One fix can move a problem: the nftables switch fixed Felix and exposed Docker's drop policy, which iptables mode had been hiding.
- In nftables, "accept" is local to a table. A drop anywhere on the same hook wins.
- Boot order can change firewall behavior. The fix should not depend on it.

## Actions

| Action | Where | Status |
|---|---|---|
| ACCEPT pod CIDR in `DOCKER-USER`, persistent via systemd (ADR 0012) | both nodes | done |
| Keep the smoke test (step 1.11) and run it after every network change | lab README | done |
| Drill: restart Docker and reboot a node, then check that the rules come back and the smoke test passes | step 1.13 (reboot 2026-11-05, Docker restart 2026-11-09) | done |
| Step 5 (Cilium): add `10.245.0.0/16` to the script during the migration and remove `10.244.0.0/16` after it | step 5 | open |
| Alert on pod-to-pod connectivity (for example a blackbox probe between nodes) | step 2 | open |
