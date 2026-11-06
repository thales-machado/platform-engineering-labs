# 0015. Kubelet serving certificates from the cluster CA

- Status: accepted
- Date: 2026-11-06

## Context

metrics-server (needed for `kubectl top` and the HPA) reads metrics from each kubelet on port 10250 over TLS. With kubeadm, each kubelet serves a self-signed certificate (`CN=<node>-ca@<timestamp>`), which metrics-server rejects.

## Options

- **`--kubelet-insecure-tls` on metrics-server**: one flag, no certificate check. Anyone answering on 10250 could feed fake metrics, and those metrics drive autoscaling.
- **`serverTLSBootstrap: true` on the kubelets**: each kubelet requests a serving certificate from the cluster CA through a CSR (signer `kubernetes.io/kubelet-serving`), approved with `kubectl certificate approve`. This is how managed clusters work, and the Certificates API is a CKA topic.

## Decision

`serverTLSBootstrap: true` in the cluster-wide `kubelet-config` ConfigMap (for nodes that join or upgrade later) and in `/var/lib/kubelet/config.yaml` on both nodes. CSRs approved by hand, after checking that the requestor is `system:node:<node>`. metrics-server runs without the insecure flag.

## Consequences

- Kubelet certificates are signed by the cluster CA (`issuer=CN=kubernetes`, `subject=CN=system:node:<node>`), so any client can verify them.
- Kubernetes never auto-approves kubelet serving CSRs. Every renewal (about once a year) waits for approval; if nobody approves it, metrics-server breaks when the old certificate expires.
- Follow-up: kubelet-csr-approver, a controller that approves only CSRs whose names and IPs match real nodes.
- Approved CSR objects are garbage-collected by the controller manager after about an hour; deleting one never revokes the certificate already on the node.
