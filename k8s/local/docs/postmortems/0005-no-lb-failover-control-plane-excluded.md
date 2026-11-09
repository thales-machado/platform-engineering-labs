# PM-0005: No LoadBalancer failover when zangetsu rebooted

- ID: PM-0005
- Date: 2026-11-05
- Status: resolved
- Severity: medium (LoadBalancer IP down for about 75 seconds; lab cluster only)
- Found during: step 1.15 (MetalLB failover drill)

## Summary

The test Service `lb-test` had its IP announced by zangetsu. During a planned reboot of zangetsu, a request loop from a PC on the LAN failed for about 75 seconds. The IP never moved to urahara: kubeadm had labeled urahara with `node.kubernetes.io/exclude-from-external-load-balancers`, and MetalLB never announces from a node with that label. After removing the label (ADR 0013), the same drill had no failed requests.

## Timeline (2026-11-05, UTC-3)

| Time | Event |
|---|---|
| 20:39 | `lb-test` gets `.241` from the pool; `servicel2statuses` shows zangetsu announcing. `curl` returns `200 OK`. |
| 20:46 | Request loop starts on a PC (one request per second, 2-second timeout). |
| ~20:49 | zangetsu drained (nginx pod moves to urahara) and rebooted. |
| 20:49:48 | First failed request. |
| 20:50:27 | urahara speaker log: `failed to join <zangetsu>:7946: no route to host` (zangetsu down). No `serviceAnnounced` from urahara. |
| 20:51:02 | Requests succeed again. `servicel2statuses` shows zangetsu announcing again: the IP came back with zangetsu, it never failed over. |
| 21:00 | Cause found: the `kubeadm init` output lists the label `node.kubernetes.io/exclude-from-external-load-balancers` on urahara. |
| 21:05 | Label removed. Drill repeated: `servicel2statuses` shows urahara announcing during the reboot, no failed requests. |

## Impact

- `lb-test` unreachable from the LAN for about 75 seconds (20:49:48 to 20:51:00).
- Only a test Service; no real workload was exposed yet.

## Root cause

kubeadm marks the control-plane node with `node.kubernetes.io/exclude-from-external-load-balancers`, for clusters with dedicated control planes. MetalLB's speaker skips nodes with that label. In this cluster the control plane also runs workloads (ADR 0007), but the label stayed, so zangetsu was the only node allowed to announce LoadBalancer IPs.

## What fixed it

Removing the label from urahara (ADR 0013). The repeated drill moved the IP to urahara and had no failed requests.

## Lessons

- Removing the control-plane taint (ADR 0007) was only half of "the control plane is also a worker". kubeadm adds a second marker for load balancers.
- The first hypothesis (memberlist between speakers) was wrong. The logs showed no announcement at all from urahara, which pointed to eligibility, not detection.
- A failover is only tested when the node that owns the IP goes down. The urahara reboot passed because urahara was never the owner.
- Measuring from outside the cluster (a loop on a PC) gave the real number: 75 seconds.

## Actions

| Action | Where | Status |
|---|---|---|
| Remove the exclude label from urahara (ADR 0013) | cluster | done |
| Repeat the failover drill | step 1.15 | done |
| Check the label again after `kubeadm upgrade` to 1.37 | ADR 0010 upgrade step (README 1.23: label still removed on 2026-11-09) | done |
| Alert when a LoadBalancer IP has no announcing node | step 2 | open |
