# SLO: lab-app availability

- Service: `lab-app` (podinfo), reached at `https://app.lab.thalespm.me`
- Owner: Thales
- Since: 2026-11-16
- Decision: [ADR 0017](../adr/0017-slo-measured-outside-the-cluster.md)

## Objective

| | |
|---|---|
| SLI | successful probes / total probes of `/healthz` |
| Measured by | homelab blackbox-exporter, every 15s, stored in VictoriaMetrics |
| Target | 99.9% |
| Window | rolling 30 days |
| Error budget | 43m 12s per 30 days |

A probe counts as good when it returns a 2xx within the blackbox timeout of 5s. Everything else is bad: timeouts, TLS failures, 5xx, DNS failures, and the probe being unable to reach the LoadBalancer address.

## Queries

Availability over the window:

```promql
avg_over_time(probe_success{instance="https://app.lab.thalespm.me/healthz"}[30d])
```

Error budget remaining, as a fraction of the budget:

```promql
1 - ((1 - avg_over_time(probe_success{instance="https://app.lab.thalespm.me/healthz"}[30d])) / 0.001)
```

Negative means the budget is spent and the SLO is missed.

## Burn-rate alerts

A burn rate of 1 spends the whole budget exactly at the end of the window. Higher rates spend it sooner.

| Alert | Long window | Short window | Burn rate | Error rate | Budget gone in | Severity |
|---|---|---|---|---|---|---|
| fast burn | 1h | 5m | 14.4x | 1.44% | ~2 days | critical |
| slow burn | 6h | 30m | 6x | 0.6% | ~5 days | warning |

Both conditions must hold at once. The long window says the problem is real, the short window says it is still happening, so an alert does not keep firing about an outage that ended twenty minutes ago.

## What spending the budget means

This is a lab, so there is no release freeze to trigger. The policy is narrower and still useful:

- Budget under 50%: no planned maintenance on the cluster until the next window, unless it is the fix.
- Budget exhausted: the next piece of work is reliability, not a new step of the lab, and the month gets a postmortem even if no single incident deserved one.

## Known blind spots

- A network failure between the homelab host and the cluster is recorded as the service being down. One prober, one path.
- `/healthz` does not touch PostgreSQL, so a broken database is invisible here.
- The probe runs on the LAN, so it says nothing about reachability from outside the house.

## History

| Window ending | Availability | Budget used | Notes |
|---|---|---|---|
| 2026-11-16 | 100% (5 days of data) | 0% | window still filling, full on 2026-12-11 |
