# 0013. urahara can announce LoadBalancer IPs

- Status: accepted
- Date: 2026-11-05
- Follows: ADR 0005 (MetalLB L2), ADR 0007 (untainted control plane)

## Context

`kubeadm init` labels the control-plane node with `node.kubernetes.io/exclude-from-external-load-balancers`. MetalLB respects that label: its speaker never announces LoadBalancer IPs from a labeled node.

In this two-node cluster, urahara is the only control plane and also runs workloads (ADR 0007). With the label, only zangetsu could announce LoadBalancer IPs. The first failover drill showed it: rebooting zangetsu cut the test Service for about 75 seconds, and the IP never moved to urahara (PM-0005).

## Options

- **Keep the label**: production default, where control planes are dedicated. Here it makes zangetsu a single point of failure for all LoadBalancer traffic.
- **Remove the label from urahara**: both nodes can announce, so an IP can fail over in either direction.

## Decision

Remove `node.kubernetes.io/exclude-from-external-load-balancers` from urahara.

```bash
kubectl label node urahara node.kubernetes.io/exclude-from-external-load-balancers-
```

## Consequences

- LoadBalancer IPs survive the loss of either node.
- The control plane also takes ingress traffic. Acceptable in a lab with no dedicated control plane.
- kubeadm may add the label again during `kubeadm upgrade` (ADR 0010). Check after the upgrade to 1.37:
  `kubectl get node urahara --show-labels | tr ',' '\n' | grep exclude`
