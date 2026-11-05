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
| 0 | Diagram | done |
| 1 | Cluster and workloads | in progress |
| 2 | Observability | planned |
| 3 | SLI, SLO and error budget | planned |
| 4 | GitOps and progressive delivery | planned |
| 5 | CNI migration: Calico to Cilium | planned |

### 0. Diagram

Architecture drawn before any install. Reviewed and approved on 2026-11-05. Decisions:

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

#### 1.1 Preflight

Read-only checks on both nodes before any change. On Debian, `sysctl` and `swapon` live in `/usr/sbin`, which is not in a normal user's PATH: run them with `sudo` or read `/proc` directly.

```bash
nproc; free -h; df -h /
cat /proc/swaps
sudo ss -tlnp | grep -E ':(80|443|6443|10250) '
lsmod | grep -E 'overlay|br_netfilter'
sudo sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
containerd config dump | grep -A2 disabled_plugins
```

Results (2026-11-05):

| Check | urahara | zangetsu | Needed for kubeadm |
|---|---|---|---|
| CPU / RAM available | 16 threads / 19 GiB | 4 cores / 4.6 GiB | 2 CPU / 2 GiB minimum |
| Swap | 28 GiB disk partition, on | 2 GiB zram, on | off (default kubelet config) |
| Ports 80/443 | 80 used by Docker (node IP only) | 80 and 443 used by Docker (all addresses) | free for Traefik only if it uses hostPort; with MetalLB IPs it does not conflict |
| Ports 6443/10250 | free | free | free |
| `overlay` module | loaded | loaded | loaded |
| `br_netfilter` module | not loaded | not loaded | loaded |
| `net.ipv4.ip_forward` | 1 | 1 | 1 |
| `bridge-nf-call-iptables` | missing (module not loaded) | missing (module not loaded) | 1 |
| containerd CRI plugin | disabled | disabled | enabled (ADR 0002) |

To fix before `kubeadm init`: swap, `br_netfilter` and its sysctls, and the CRI plugin.

#### 1.2 Kernel modules and sysctl

Load `br_netfilter` now and on every boot, and set the network values kubeadm checks. Run on both nodes.

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system | grep -E 'bridge-nf|ip_forward'
```

Expected: the three values show `= 1`. `bridge-nf-call-iptables` also changes how Docker bridge traffic is filtered, so check the Compose services after the change:

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | head
```

urahara and zangetsu (2026-11-05): all three values `= 1`, all containers still up.

#### 1.3 Swap off

kubelet does not start with swap on (default config). Each node creates swap in a different way, so each needs a different fix.

urahara: swap partition in `/etc/fstab`.

```bash
sudo swapoff -a
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
sudo systemctl daemon-reload
grep swap /etc/fstab
cat /proc/swaps
```

Expected: the swap line in fstab starts with `#`, and `/proc/swaps` shows only the header.

zangetsu: zram created at boot by `rpi-swap` (Raspberry Pi OS on Debian 13), configured in `/etc/rpi/swap.conf`. Swap is turned off with a drop-in, which survives package updates.

```bash
sudo mkdir -p /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=none\n' | sudo tee /etc/rpi/swap.conf.d/90-k8s-no-swap.conf
sudo swapoff -a
cat /proc/swaps
```

Finding (2026-11-05): on zangetsu, `swapoff -a` failed with `Cannot allocate memory`. The kernel moved part of the swap back to RAM (about 520 MB down to 110 MB) and then stopped, because there was not enough free RAM for the rest. The drop-in is already in place, so a reboot starts the node with no swap. Lesson: the Raspberry Pi has little memory headroom with the current Docker services, which matters for scheduling (ADR 0003, node affinity).

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
