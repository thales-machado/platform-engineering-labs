# 0007. Run workloads on the control plane node

- Status: accepted
- Date: 2026-10-31

## Context

The cluster has two nodes. urahara (28 GiB) is the control plane. zangetsu (8 GiB, about 4.6 GiB available) is the only worker.

## Options

- **Keep the control-plane taint**: production pattern, but every workload runs on the Raspberry Pi.
- **Remove the taint**: workloads use both nodes.

## Decision

Remove the `node-role.kubernetes.io/control-plane:NoSchedule` taint from urahara.

## Consequences

- Most capacity is available, and the observability stack fits.
- Workloads can compete with the apiserver and etcd. Resource requests and limits are required on every workload.
- This is not a production pattern. Production clusters keep dedicated control plane nodes, usually three.
