# 0017. SLO measured outside the cluster, on a 30-day window

- Status: accepted
- Date: 2026-11-16

## Context

Step 3 needs an SLI, an SLO and an error budget for a workload of the lab. Two constraints decide most of the design before any target is chosen.

In-cluster Prometheus keeps 7 days (ADR 0016). An SLO over 30 days cannot be computed from storage that forgets after a week.

PM-0006 left the cluster unreachable for 41 hours. A measurement taken inside the cluster records nothing during exactly the period the budget should be consumed, so the worst month would look like the best one.

The homelab blackbox-exporter has probed `app.lab.thalespm.me/healthz` every 15s since 2026-11-11 (step 2.2), and VictoriaMetrics keeps that series far longer than 30 days.

## Options

- **In-cluster Prometheus with recording rules**: the Kubernetes-native answer, and what most tutorials show. Fails both constraints: 7-day retention and blind during an outage.
- **Remote-write from the cluster to VictoriaMetrics**: keeps the data long enough, still blind while the cluster is down, and adds a storage path for data that is already being collected from outside.
- **The existing external probe**: already running, already stored, and it measures what a user would see. It does not see anything a user cannot see, which is a limitation and also the point.

## Decision

The SLI is the ratio of successful probes from the homelab blackbox-exporter, stored in VictoriaMetrics, over a rolling 30-day window.

Target: **99.9%**, an error budget of **43m 12s per 30 days**.

The target comes from measurement, not preference. The service did 100% over its first 7 days, including a full node drain, so 99% would be unfailable and teach nothing. 99.99% is 4m 19s a month, less than one restart of Traefik, which still runs a single replica: an SLO breached by normal maintenance trains people to ignore it.

Alerting uses two-window burn rates rather than a threshold on availability: fast burn at 14.4x the budget rate over 1h confirmed by 5m, slow burn at 6x over 6h confirmed by 30m. The short window stops an alert from firing about an outage that has already ended.

## Consequences

The SLI measures the whole path, DNS, MetalLB, Traefik, the Gateway and the pods. A failure in any of them spends budget, which is correct for a user-facing objective and useless for attributing the cause. Attribution stays with the twelve component alerts from step 2.

Blind spots are accepted and worth naming: a network failure between the homelab host and the cluster is recorded as the service being down, and anything a `/healthz` request does not touch, such as the database path, is invisible to this SLI.

The window is honest before it is full. The probe has 5 days of history on 2026-11-16, so until 2026-12-11 the 30-day number is partial, the dashboard says so, and the burn-rate alerts work from the first day because they read 1h and 6h windows.

Latency is deliberately left out of this ADR. The only latency available is the probe's own duration from one host on the same LAN, which says more about the LAN than about the service.
