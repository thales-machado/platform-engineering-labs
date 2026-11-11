# External monitoring of the lab cluster

Availability of this cluster is watched from **outside** it, by the homelab stack
that runs independently on zangetsu. That is the lesson of
[PM-0006](../../docs/postmortems/0006-etcd-crash-corrupted-image-layer.md): the control
plane was down for 41 hours and nothing noticed, and an Alertmanager running inside the
cluster would have been down with it.

The configuration itself lives in the homelab repository (private), because that is where
the monitoring stack is defined. It is VictoriaMetrics for scraping and Grafana for
alerting, not Prometheus and Alertmanager:

| What | Where (homelab repo) |
|---|---|
| `http_2xx_insecure` blackbox module | `infra/observability/metrics/exporters/blackbox-exporter/config/blackbox.yml` |
| Scrape job `blackbox-k8s-lab` and the app target | `infra/observability/metrics/victoriametrics/prometheus.yml` |
| Alert rules `k8s-lab-apiserver-down`, `k8s-lab-app-down` | `infra/observability/metrics/grafana/provisioning/alerting/rules.yaml` |
| Uptime Kuma monitors, group "Lab K8s" | `scripts/setup/setup-uptime-kuma.py` |

## What it watches

- **`/readyz` on the API server.** Anonymous access to `/healthz`, `/livez`, `/readyz` and
  `/version` is allowed by default on a kubeadm cluster, so the probe needs no credentials.
  The certificate is signed by the cluster CA, which the homelab does not trust, hence the
  insecure module. Mounting the cluster's `ca.crt` there instead is a follow-up.
- **`/healthz` on the app**, through the Ingress and the real certificate. Two probes separate
  "the control plane is down" from "the app is down", a distinction that was invisible during
  PM-0006.

Both alerts fire after 2 minutes, with `noDataState: Alerting`: no data from the probe is
itself the failure.
