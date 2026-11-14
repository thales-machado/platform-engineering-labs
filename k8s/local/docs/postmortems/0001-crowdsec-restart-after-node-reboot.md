# PM-0001: CrowdSec restarted on urahara after zangetsu reboot

- ID: PM-0001
- Date: 2026-11-05
- Status: resolved
- Severity: low (homelab service, no data loss)
- Found during: step 1.3 (swap off) and 1.4 (container runtime) checks

## Summary

zangetsu was rebooted to finish turning off swap (step 1.3). CrowdSec runs on urahara, but it reads Traefik logs from Loki, which runs on zangetsu. With Loki down, CrowdSec failed its startup check, exited, and was restarted by Docker until Loki came back.

## Timeline (2026-11-05, UTC-3)

| Time | Event |
|---|---|
| ~14:56 | `sudo reboot` on zangetsu. |
| 14:57:26 | CrowdSec on urahara: `Error checking if Loki is ready ... no route to host`. |
| 14:57:32 | CrowdSec: `fatal ... loki is not ready: context deadline exceeded`. Container exits; Docker restarts it. |
| 14:57:55 | Second fatal with the same error; Docker restarts it again. |
| 14:58:07 | CrowdSec: `Loki is ready`. Service back to normal. |
| 15:06 | Found by chance: `docker ps` on urahara shows CrowdSec "Up 8 minutes" while the other containers show hours or days. |

## Impact

- CrowdSec on urahara was down for about 35 seconds (14:57:32 to 14:58:07), with two restarts.
- The Traefik bouncer that asks CrowdSec for decisions runs on zangetsu, which was rebooting at the same time, so no request was served without a decision.
- No alert fired. The restart was found by reading `docker ps`.

## Root cause

A hidden dependency between the two servers: CrowdSec on urahara needs Loki on zangetsu at startup. When Loki is not reachable, CrowdSec does not wait or degrade: it exits with `fatal`. The reboot plan did not list services on the other node that depend on zangetsu.

## What fixed it

Nothing was done by hand. Docker's restart policy restarted CrowdSec until Loki was ready.

## Lessons

- Rebooting one node can affect services on the other one. Cross-node dependencies must be known before maintenance.
- Docker's restart policy hid the problem: the service recovered, but nobody was told.
- The same pattern matters inside Kubernetes: a pod that exits when a dependency is down goes into CrashLoopBackOff. Readiness probes and retry logic are the right tools, not a crash.

## Actions

| Action | Where | Status |
|---|---|---|
| Before rebooting a node, list services on the other node that depend on it (CrowdSec -> Loki is the first known one) | lab checklist, private environment notes | done |
| Alert on container restarts, so a restart is never found by chance | homelab observability (cAdvisor `container_start_time_seconds`, 2026-11-09) | done |
| In step 2 (observability), alert on pod restarts and CrashLoopBackOff from day one | step 2.4, rule `k8s-lab-crashloop` | done (2026-11-14) |
