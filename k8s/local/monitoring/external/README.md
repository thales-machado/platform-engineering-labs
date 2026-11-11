# External monitoring of the lab cluster

These files are **not** applied to the cluster. They are applied to the monitoring stack that runs outside it, on the homelab host, which keeps working when the lab control plane is down.

That separation is the lesson of [PM-0006](../../docs/postmortems/0006-etcd-crash-corrupted-image-layer.md): the control plane was down for 41 hours and nothing noticed, and an Alertmanager running inside the cluster would have been down with it.

| File | Where it goes |
|---|---|
| `blackbox-targets.yaml` | scrape jobs for the homelab Prometheus |
| `alerts-k8s-lab.yaml` | alert rules for the homelab Prometheus |

Everything in-cluster (ServiceMonitors, PrometheusRules, Grafana dashboards) lives in `../in-cluster/` and watches the workloads, not the control plane's availability.

## What it watches

- **`/readyz` on the API server.** Anonymous access to `/healthz`, `/livez`, `/readyz` and `/version` is allowed by default on a kubeadm cluster, so the probe needs no credentials.
- **`/healthz` on the app**, through the Ingress and the real certificate. Two probes separate "the control plane is down" from "the app is down", which is exactly the distinction that was invisible during PM-0006.
- **The node ports**, as a cheap liveness check of each host.

## Note on TLS

`insecure_skip_verify: true` is used for the API server probe because its certificate is signed by the cluster CA, which the homelab does not trust. Copying `/etc/kubernetes/pki/ca.crt` to the monitoring host and pointing `ca_file` at it is the better version, and a follow-up.
