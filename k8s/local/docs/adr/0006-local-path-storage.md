# 0006. local-path-provisioner for persistent volumes

- Status: accepted
- Date: 2026-10-31

## Context

Workloads need PersistentVolumes (Postgres from 0009, Prometheus, Loki). Two nodes, and the arm64 node has 8 GiB of RAM shared with homelab services.

## Options

- **local-path-provisioner**: a directory on the node's disk. Very light.
- **Longhorn**: replicated block storage, snapshots, S3 backups. Runs several pods on every node, needs `open-iscsi`, and works best with 3 nodes.
- **NFS**: shared, but a single point of failure and slow for databases.

## Decision

local-path-provisioner.

## Consequences

- A volume lives on one node. A pod with a PVC is pinned to that node.
- Losing the node loses the data. Database safety comes from CloudNativePG replicas and backups, not from storage.
- Longhorn can be an optional step later.
