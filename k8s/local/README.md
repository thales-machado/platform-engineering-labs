# Kubernetes lab: local

## Goal

Build a Kubernetes cluster from scratch with kubeadm on two homelab servers, then run real workloads on it with observability, SLOs and GitOps. Every step is done by hand first, to learn how each part works. It also serves as CKA preparation.

## Diagram

![Lab diagram](diagram.png)

Source: [diagram.mmd](diagram.mmd). Render with `tools/diagram/render.sh k8s/local`.

## Prerequisites

| Node | Hardware | CPU | RAM | Disk | OS |
|---|---|---|---|---|---|
| urahara | GMKtec NucBox K8 | AMD Ryzen 7 8845HS, 8C/16T (amd64) | 28 GiB | NVMe | Debian 13 |
| zangetsu | Raspberry Pi 5 | ARM Cortex-A76, 4 cores (arm64) | 8 GiB | NVMe | Debian 13 |

Both servers also run other services with Docker Compose on ports 80 and 443. The cluster must live next to them.

Tool versions are recorded in each step.

## Steps

| # | Step | Status |
|---|---|---|
| 0 | Diagram | in progress |
| 1 | Cluster and workloads | planned |
| 2 | Observability | planned |
| 3 | SLI, SLO and error budget | planned |
| 4 | GitOps and progressive delivery | planned |
| 5 | CNI migration: Calico to Cilium | planned |

### 0. Diagram

Architecture drawn before any install. Decisions:

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-kubeadm.md) | Build the cluster with kubeadm |
| [0002](docs/adr/0002-shared-containerd-with-cri.md) | Use Docker's containerd with the CRI plugin enabled |
| [0003](docs/adr/0003-multi-arch-images.md) | Multi-arch images by default, node affinity when needed |
| [0004](docs/adr/0004-calico-then-cilium.md) | Calico first, migrate to Cilium in step 5 |
| [0005](docs/adr/0005-metallb-l2.md) | MetalLB in L2 mode for LoadBalancer IPs |
| [0006](docs/adr/0006-local-path-storage.md) | local-path-provisioner for persistent volumes |
| [0007](docs/adr/0007-untainted-control-plane.md) | Run workloads on the control plane node |
| [0008](docs/adr/0008-traefik.md) | Traefik as Ingress and Gateway API controller |
| [0009](docs/adr/0009-cloudnativepg.md) | CloudNativePG as the database operator |

### 1. Cluster and workloads

Planned.

### 2. Observability

Planned.

### 3. SLI, SLO and error budget

Planned.

### 4. GitOps and progressive delivery

Planned.

### 5. CNI migration: Calico to Cilium

Planned.

## Teardown

Filled in when step 1 installs the cluster.

## Lessons learned

None yet.
