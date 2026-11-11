# 0016. In-cluster observability stack

- Status: accepted
- Date: 2026-11-11

## Context

Step 2 needs metrics, dashboards, alerts and logs for the cluster. The homelab on zangetsu already runs Prometheus, Grafana and Loki in Docker, outside Kubernetes, with 15-day log retention. The postmortems of step 1 left four alerts open (PM-0001, PM-0002, PM-0003, PM-0005), and step 3 needs SLIs and error budgets on top of the same data.

## Options

- **Reuse the homelab stack**: scrape the cluster from outside and send logs to the existing Loki. Cheapest in memory, nothing new to install. Teaches nothing Kubernetes-native: no Operator, no ServiceMonitor, no PrometheusRule, and the alerts live outside this repo.
- **In-cluster, kube-prometheus-stack and Loki**: the Prometheus Operator, Alertmanager, Grafana and Loki run as workloads of the lab cluster, configured by CRDs that live in this repo next to the manifests they monitor.
- **Hybrid**: in-cluster Prometheus with remote-write to the homelab for long-term storage. Realistic for production, but it adds a second storage path before there is anything worth keeping for months.

## Decision

In-cluster, with kube-prometheus-stack (Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) and Loki with Grafana Alloy as a DaemonSet.

The lab cluster monitors itself. Scrape configuration is a `ServiceMonitor` or `PodMonitor` next to each component, and every alert is a `PrometheusRule` committed here, so the step 1 postmortems close with code instead of a note.

Both Prometheus and Loki are pinned to urahara (28 GiB RAM, NVMe) with local-path volumes. zangetsu (7.9 GiB) runs only the DaemonSets, node-exporter and Alloy.

## Consequences

- The monitoring of the cluster dies with the cluster. That is acceptable in a lab, and the failure itself is worth a drill: a dashboard that goes blank during a node drain is a real lesson.
- Prometheus and Loki hold local-path volumes on urahara, so draining that node leaves them `Pending` until it comes back, exactly like `lab-pg`. Retention stays short: 7 days for metrics, 7 days for logs.
- Two Grafanas exist on the network, one in the homelab and one in the cluster. The cluster one is reachable at its own hostname under `lab.thalespm.me` through the shared Gateway.
- The Pi carries the per-node agents only. If memory still gets tight, Alloy there is the first thing to tune.
- Step 3 (SLIs, SLOs and error budgets) and step 4 (GitOps) build on these CRDs, so they stay in this repo and move to Argo CD unchanged.
