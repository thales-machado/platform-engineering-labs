# 0010. Install Kubernetes 1.36, then upgrade to 1.37

- Status: accepted
- Date: 2026-11-05

## Context

Kubernetes 1.37 is the current minor release. The lab is also CKA preparation, and upgrading a cluster with `kubeadm upgrade` is one of the exam tasks. It is also a common production task: control plane first, then each node, with drain and uncordon.

## Options

- **Install 1.37 directly**: simplest, but no upgrade practice until 1.38 is out.
- **Install 1.36, upgrade to 1.37 inside step 1**: one extra procedure, done on a real two-node cluster with real workloads.

## Decision

Install 1.36 on both nodes. After the cluster and the first workloads run, upgrade to 1.37 with `kubeadm upgrade`, one node at a time.

## Consequences

- The apt repo for 1.36 (`pkgs.k8s.io/core:/stable:/v1.36`) is configured first. The upgrade changes the repo to 1.37.
- `kubeadm`, `kubelet` and `kubectl` are held with `apt-mark hold` and only unheld during the upgrade.
- Both nodes run exactly the same patch version, picked from `apt-cache madison`.
- The upgrade is a good moment for a drill: workloads must keep running while a node is drained.
