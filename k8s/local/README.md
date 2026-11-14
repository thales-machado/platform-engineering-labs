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

## Layout

```
components/<name>/   everything one component needs, Helm values and manifests together
charts/lab-app/      the chart written by hand for this lab
docs/adr/            decisions
docs/postmortems/    incidents
monitoring/external/ where the out-of-cluster probes live, in the homelab repository
```

One folder per component rather than one folder per tool, because a change to a
component usually touches both its values and its manifests, and because step 4
points a GitOps controller at a directory.

Commands run from `k8s/local`.

## Steps

| # | Step | Status |
|---|---|---|
| 0 | Diagram | done |
| 1 | Cluster and workloads | done |
| 2 | Observability | done |
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
| [0010](docs/adr/0010-install-1-36-then-upgrade.md) | Install Kubernetes 1.36, then upgrade to 1.37 (added in step 1) |
| [0011](docs/adr/0011-nftables-dataplane.md) | nftables data plane for kube-proxy and Calico (added in step 1) |
| [0012](docs/adr/0012-docker-user-accept-pod-cidr.md) | Accept pod traffic in Docker's DOCKER-USER chain (added in step 1) |
| [0013](docs/adr/0013-urahara-announces-lb-ips.md) | urahara can announce LoadBalancer IPs (added in step 1) |
| [0014](docs/adr/0014-cert-manager-wildcard-dns01.md) | cert-manager with a Let's Encrypt wildcard certificate (DNS-01) (added in step 1) |
| [0015](docs/adr/0015-kubelet-serving-certificates.md) | Kubelet serving certificates from the cluster CA (added in step 1) |
| [0016](docs/adr/0016-in-cluster-observability-stack.md) | In-cluster observability stack: kube-prometheus-stack and Loki (added in step 2) |

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

fstab may not be the only source. On urahara, systemd also activates the partition by its GPT type (`systemd-gpt-auto-generator`), so check what systemd loaded with `systemctl list-units --type=swap --all` and see step 1.13.

zangetsu: zram created at boot by `rpi-swap` (Raspberry Pi OS on Debian 13), configured in `/etc/rpi/swap.conf`. Swap is turned off with a drop-in, which survives package updates.

```bash
sudo mkdir -p /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=none\n' | sudo tee /etc/rpi/swap.conf.d/90-k8s-no-swap.conf
sudo swapoff -a
cat /proc/swaps
```

Finding (2026-11-05): on zangetsu, `swapoff -a` failed with `Cannot allocate memory`. The kernel moved part of the swap back to RAM (about 520 MB down to 110 MB) and then stopped, because there was not enough free RAM for the rest. The drop-in is already in place, so a reboot starts the node with no swap. Lesson: the Raspberry Pi has little memory headroom with the current Docker services, which matters for scheduling (ADR 0003, node affinity).

Fix: reboot zangetsu. After the reboot (2026-11-05), `/proc/swaps` shows only the header on both nodes, zangetsu has 5.1 GiB available, and all Docker containers came back.

#### 1.4 Container runtime (ADR 0002)

Align containerd on both nodes and enable the CRI plugin, in one restart per node. Both nodes had different versions (2.3.3 and 2.2.6). After `sudo apt update`, the Docker repo has 2.4.2-3 for amd64 and arm64, so both nodes upgrade to it:

```bash
apt-cache madison containerd.io | head -6
```

Then, one node at a time:

```bash
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
sudo apt install -y -o Dpkg::Options::="--force-confold" containerd.io=2.4.2-3~debian.13~trixie
sudo apt-mark hold containerd.io

containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -nE 'SystemdCgroup|disabled_plugins' /etc/containerd/config.toml

sudo systemctl restart containerd
containerd --version
sudo ctr plugins ls | grep -i cri
docker ps --format '{{.Names}}\t{{.Status}}' | head
```

- `--force-confold` keeps Docker's config during the install; it is replaced right after with the full default, where CRI is enabled.
- `apt-mark hold` stops an `apt upgrade` from changing the Kubernetes runtime by surprise.
- Expected: `disabled_plugins = []`, `SystemdCgroup = true`, version 2.4.2, the three CRI plugins with status `ok`, Docker containers still up. A containerd restart does not stop running containers: each one has its own shim.

urahara and zangetsu (2026-11-05): all as expected. Both nodes run containerd 2.4.2-3 with CRI enabled, held.

Incident: rebooting zangetsu in step 1.3 restarted CrowdSec on urahara, which reads logs from Loki on zangetsu. Postmortem: [PM-0001](docs/postmortems/0001-crowdsec-restart-after-node-reboot.md).

#### 1.5 kubeadm, kubelet and kubectl (ADR 0010)

Add the Kubernetes apt repo for 1.36. The minor version is part of the URL, so apt only sees 1.36 packages. Run on both nodes.

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
apt-cache madison kubeadm | head -3
```

Both nodes (2026-11-05): latest patch is 1.36.6-1.1, so both install exactly that version and hold it:

```bash
sudo apt-get install -y kubelet=1.36.6-1.1 kubeadm=1.36.6-1.1 kubectl=1.36.6-1.1
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
kubeadm version -o short
kubectl version --client
systemctl status kubelet --no-pager | head -5
```

Expected: version v1.36.6 for kubeadm and kubectl. kubelet shows `inactive (dead)`: `systemctl enable` without `--now` only enables it for boot, and `kubeadm init` starts it.

#### 1.6 Control plane on urahara (`kubeadm init`)

A plain `kubeadm init` would use defaults that do not fit this lab: no pod CIDR (Calico needs `10.244.0.0/16`, ADR 0004) and an automatic node IP (the node has a second, unused Ethernet port). It also needs `sudo`: run without it, the preflight stops with `[ERROR IsPrivilegedUser]`.

So the cluster starts from a config file. `<URAHARA_IP>` is the node's LAN IP.

```bash
cat <<'EOF' > ~/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: <URAHARA_IP>
  bindPort: 6443
nodeRegistration:
  name: urahara
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: <URAHARA_IP>
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.6
clusterName: lab-local
controlPlaneEndpoint: <URAHARA_IP>:6443
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

kubeadm config validate --config ~/kubeadm-config.yaml
sudo kubeadm config images pull --config ~/kubeadm-config.yaml
sudo kubeadm init --config ~/kubeadm-config.yaml
```

- `kubernetesVersion` is fixed, so kubeadm does not look up the newest release online.
- `cgroupDriver: systemd` matches `SystemdCgroup = true` in containerd (step 1.4).
- Images pulled for 1.36.6: kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy v1.36.6, coredns v1.14.2, pause 3.10.2, etcd 3.6.8-0.

urahara (2026-11-05): `Your Kubernetes control-plane has initialized successfully!` The API server certificate covers the node IP and the first service IP (`10.96.0.1`). The output ends with a `kubeadm join` command with a token and a CA hash: keep it out of Git, the token expires in 24 hours.

#### 1.7 kubectl access and control-plane taint (ADR 0007)

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl taint nodes urahara node-role.kubernetes.io/control-plane:NoSchedule-
```

urahara (2026-11-05): node `NotReady` (no CNI yet), INTERNAL-IP is the main port, runtime `containerd://2.4.2`. etcd, kube-apiserver, kube-controller-manager, kube-scheduler and kube-proxy `Running`; both CoreDNS pods `Pending` until the CNI is installed. Taint removed: `node/urahara untainted`.

#### 1.8 Join zangetsu

The join also uses a config file, so the node IP is explicit. `<TOKEN>` and `<CA_HASH>` come from the `kubeadm init` output and stay out of Git.

```bash
cat <<'EOF' > ~/kubeadm-join.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: <URAHARA_IP>:6443
    token: <TOKEN>
    caCertHashes:
      - sha256:<CA_HASH>
nodeRegistration:
  name: zangetsu
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: <ZANGETSU_IP>
EOF

sudo kubeadm join --config ~/kubeadm-join.yaml
```

zangetsu (2026-11-05): `This node has joined the cluster`. Two warnings, both harmless: `missing optional cgroups: hugetlb` (the Raspberry Pi kernel has no hugetlb cgroup; nothing in the lab uses huge pages) and the kube-proxy `bindAddress` recommendation (`::` instead of `0.0.0.0`, only relevant for IPv6). Both nodes show `NotReady` until Calico is up.

#### 1.9 Calico (ADR 0004)

Latest Calico release on 2026-11-05:

```bash
curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | grep tag_name
```

`v3.33.0`. Install the operator, then the Installation from [components/calico/installation.yaml](components/calico/installation.yaml):

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
kubectl create -f components/calico/installation.yaml
watch kubectl get tigerastatus
```

Result (2026-11-05): everything available on urahara, but `calico` stayed `PROGRESSING` and calico-node on zangetsu stayed `0/1`. Felix panicked on every start: `iptables-nft-save failed because there are incompatible nft rules in the table nat`. Cause: Tailscale on zangetsu runs in forced nftables mode and adds native nftables rules to the shared `ip nat` table, which the iptables inside the calico-node image cannot read. Tailscale cannot use iptables mode on that kernel (no legacy `ip_tables`). Decision: move the cluster to nftables, see ADR 0011.

Note: `kubectl` on zangetsu fails with `the server could not find the requested resource`. Workers have no kubeconfig, so kubectl falls back to `localhost:8080`, where an unrelated Docker service answers. Run kubectl on urahara.

#### 1.10 Switch to the nftables data plane (ADR 0011)

kube-proxy first, because Calico's nftables mode requires it.

```bash
kubectl -n kube-system get configmap kube-proxy -o yaml | grep 'mode:'
kubectl -n kube-system get configmap kube-proxy -o yaml | sed 's/mode: ""/mode: "nftables"/' | kubectl apply -f -
kubectl -n kube-system get configmap kube-proxy -o yaml | grep 'mode:'
kubectl -n kube-system rollout restart daemonset/kube-proxy
kubectl -n kube-system rollout status daemonset/kube-proxy
kubectl -n kube-system logs daemonset/kube-proxy | grep -i -m3 nftables
```

Then Calico:

```bash
kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"linuxDataplane":"Nftables"}}}'
watch kubectl get tigerastatus
```

The operator only changes the Felix configuration: Felix reloads inside the running calico-node pods, so pod names and ages do not change. With `NFTablesMode: Auto`, Felix follows the kube-proxy mode.

Check on a node and from urahara:

```bash
sudo nft list tables
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}{"\n"}'
kubectl logs -n calico-system <calico-node-pod> -c calico-node --since=2m | grep -iE 'panic|incompatible'
```

Result (2026-11-05): new tables `ip calico`, `ip kube-proxy` and `ip6 kube-proxy`; no Felix errors since the switch; calico-node `1/1` on both nodes with no new restarts.

Leftovers: the old kube-proxy iptables chains (`KUBE-SVC-*`, `KUBE-SEP-*`, `KUBE-NODEPORTS`, `KUBE-MARK-MASQ` and others) stay in `ip nat` and `ip filter`. kube-proxy does not remove them when it switches modes. `KUBE-KUBELET-CANARY` and `KUBE-FIREWALL` belong to kubelet and stay.

Check that no base chain jumps to them (only kubelet's `KUBE-FIREWALL` should show), on both nodes:

```bash
for c in PREROUTING OUTPUT POSTROUTING; do sudo nft list chain ip nat $c | grep -E 'jump KUBE'; done
for c in INPUT FORWARD OUTPUT; do sudo nft list chain ip filter $c | grep -E 'jump KUBE'; done
```

List the orphan chains (dry run), then flush and delete them. kubelet's chains are excluded:

```bash
for t in "ip nat" "ip filter" "ip6 nat" "ip6 filter"; do
  echo "== $t"
  sudo nft list table $t 2>/dev/null | awk '/^[[:space:]]*chain KUBE-/{print $2}' | grep -vE '^KUBE-(FIREWALL|KUBELET-CANARY)$'
done

for t in "ip nat" "ip filter" "ip6 nat" "ip6 filter"; do
  chains=$(sudo nft list table $t 2>/dev/null | awk '/^[[:space:]]*chain KUBE-/{print $2}' | grep -vE '^KUBE-(FIREWALL|KUBELET-CANARY)$')
  for c in $chains; do sudo nft flush chain $t "$c"; done
  for c in $chains; do sudo nft delete chain $t "$c"; done
done
sudo nft list ruleset | grep -E 'chain KUBE-'
```

Result (2026-11-05): urahara had no leftovers (kube-proxy cleaned up there, because iptables can read its `ip nat`). zangetsu had 19 chains in `ip nat`, 4 in `ip filter` and a few in the ip6 tables, all removed. Only `KUBE-FIREWALL`, `KUBE-KUBELET-CANARY` and `KUBE-IPTABLES-HINT` remain. All pods `Running`, Docker containers up on both nodes.

Postmortem: [PM-0002](docs/postmortems/0002-calico-node-crash-nftables-rules.md).

#### 1.11 Smoke test: pod-to-pod across nodes and DNS

`Ready` nodes do not prove the pod network works. One pod on each node, then ping both ways and resolve a Service name from zangetsu (CoreDNS runs on urahara):

```bash
kubectl run net-a --image=busybox:1.36 --restart=Never --overrides='{"spec":{"nodeName":"urahara"}}' -- sleep 3600
kubectl run net-b --image=busybox:1.36 --restart=Never --overrides='{"spec":{"nodeName":"zangetsu"}}' -- sleep 3600
kubectl wait --for=condition=Ready pod/net-a pod/net-b --timeout=120s
kubectl get pods -o wide

kubectl exec net-a -- ping -c3 "$(kubectl get pod net-b -o jsonpath='{.status.podIP}')"
kubectl exec net-b -- ping -c3 "$(kubectl get pod net-a -o jsonpath='{.status.podIP}')"
kubectl exec net-b -- nslookup kubernetes.default.svc.cluster.local
```

First result (2026-11-05): 100% packet loss both ways, DNS `connection timed out`. Cause: Docker's `FORWARD` policy `drop` on urahara. In nftables mode, Calico's own table cannot override it (ADR 0012).

```bash
sudo nft list chain ip filter FORWARD | head -8
sudo nft list chain ip filter DOCKER-USER
```

urahara: `policy drop`. zangetsu: `policy accept` (forwarding was already on when Docker started). Temporary test on urahara, in memory only:

```bash
sudo nft insert rule ip filter DOCKER-USER ip saddr 10.244.0.0/16 accept
sudo nft insert rule ip filter DOCKER-USER ip daddr 10.244.0.0/16 accept
```

After it: ping `0% packet loss` (about 0.3 ms), and `nslookup` answers `10.96.0.1` through `10.96.0.10`.

#### 1.12 Make the DOCKER-USER rules permanent (ADR 0012)

On both nodes:

```bash
sudo tee /usr/local/sbin/k8s-docker-user.sh >/dev/null <<'EOF'
#!/bin/sh
# Accept Kubernetes pod traffic in Docker's DOCKER-USER chain (ADR 0012).
set -eu
CIDR=10.244.0.0/16
for dir in saddr daddr; do
  nft list chain ip filter DOCKER-USER | grep -q "ip $dir $CIDR accept" \
    || nft insert rule ip filter DOCKER-USER ip "$dir" "$CIDR" accept
done
EOF
sudo chmod 755 /usr/local/sbin/k8s-docker-user.sh

sudo tee /etc/systemd/system/k8s-docker-user.service >/dev/null <<'EOF'
[Unit]
Description=Accept Kubernetes pod traffic in Docker's DOCKER-USER chain
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/k8s-docker-user.sh
RemainAfterExit=yes

[Install]
WantedBy=docker.service
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now k8s-docker-user.service
systemctl status k8s-docker-user.service --no-pager | head -4
sudo nft list chain ip filter DOCKER-USER
```

The script is idempotent: if the rules already exist (like the temporary ones on urahara), it does not add them again.

Smoke test again after the unit (2026-11-05): ping `0% packet loss` both ways (about 0.3 ms), `nslookup` answers `10.96.0.1`. The pod network works across both nodes.

Postmortem: [PM-0003](docs/postmortems/0003-pod-traffic-dropped-by-docker-forward.md).

#### 1.13 Drill: reboot both nodes

Everything above was applied at runtime. A reboot shows what is really persistent. One node at a time, worker first.

zangetsu:

```bash
kubectl drain zangetsu --ignore-daemonsets --delete-emptydir-data   # on urahara
sudo reboot                                                          # on zangetsu
```

After the boot, on the node:

```bash
cat /proc/swaps
lsmod | grep -c br_netfilter
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
systemctl is-active containerd kubelet k8s-docker-user
sudo nft list chain ip filter FORWARD | grep policy
sudo nft list chain ip filter DOCKER-USER | grep -c 10.244.0.0/16
```

Then `kubectl uncordon zangetsu` on urahara. zangetsu (2026-11-05): all checks pass, node `Ready`. As expected, CrowdSec on urahara restarted while Loki was down (PM-0001).

urahara (the only control plane, no drain): after the reboot, `kubectl` got `connection refused`. Swap was on again, and kubelet refused to start. Cause: `systemd-gpt-auto-generator` activates the swap partition by its GPT type, without fstab. Check what systemd loaded, and turn the generator off:

```bash
systemctl list-units --type=swap --all --no-pager
sudo swapoff -a
sudo systemctl mask dev-nvme0n1p3.swap
sudo cp /etc/default/grub /etc/default/grub.bak
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 systemd.gpt_auto=0"/' /etc/default/grub
sudo update-grub
sudo reboot
```

After the second reboot: no swap, `systemd.gpt_auto=0` in `/proc/cmdline`, both nodes `Ready`. Postmortem: [PM-0004](docs/postmortems/0004-swap-back-after-reboot.md).

Note: right after boot, `k8s-docker-user` shows `inactive` until Docker starts (on urahara, about 2 minutes after boot), then `active (exited)`. That is expected: the unit is wanted by `docker.service`. After the reboot, urahara's `FORWARD` policy was `accept`, because the sysctl turns forwarding on before Docker starts; the `DOCKER-USER` rules were present anyway.

Smoke test after both reboots (2026-11-05, step 1.11 commands): ping `0% packet loss` both ways, `nslookup` answers `10.96.0.1`. The base cluster is persistent.

Docker restart drill (2026-11-09, PM-0003 action), on urahara:

```bash
sudo systemctl restart docker
sleep 15
systemctl is-active docker k8s-docker-user
sudo nft list chain ip filter FORWARD | grep policy
sudo nft list chain ip filter DOCKER-USER | grep -c 10.244.0.0/16
```

Result: both units `active`, both pod CIDR rules back in `DOCKER-USER` (count `2`). `FORWARD` policy stayed `accept` (forwarding was already on when Docker started), so the `drop` case was not exercised; the rules do not depend on it. No Kubernetes pod restarted: kubelet uses `containerd.service`, which a Docker restart does not touch. Smoke test passed: ping `0% packet loss` both ways (about 0.4 ms), `nslookup` answers `10.96.0.1`.

#### 1.14 MetalLB (ADR 0005)

Preflight, read-only. Check that the planned pool IPs are free on the LAN: ping finds devices that answer ICMP, and the ARP table finds devices that block ping. `REACHABLE` or `STALE` with a MAC address means in use; `FAILED` or `INCOMPLETE` means free.

```bash
for i in $(seq 241 249); do
  ping -c1 -W1 <LAN_PREFIX>.$i >/dev/null 2>&1 && echo "<LAN_PREFIX>.$i  answers ping (IN USE)" || echo "<LAN_PREFIX>.$i  no ping"
done
ip neigh show | grep -E '<LAN_PREFIX>\.24[1-9] '
sudo ss -tulnp | grep 7946    # memberlist port of the MetalLB speaker, on both nodes
curl -s https://api.github.com/repos/metallb/metallb/releases/latest | grep tag_name
```

Result (2026-11-05): `.241` to `.247` and `.249` free; `.248` answers ping and ARP (a device with a Raspberry Pi MAC), so it is excluded. Pool: `.241` to `.247` (7 IPs). Port 7946 free. Latest MetalLB: `v0.16.2`.

kube-proxy in nftables mode needs no extra setting for MetalLB L2. The `strictARP` change found in many guides is only for IPVS mode.

Install (official manifest), then the pool from [components/metallb/pool.yaml](components/metallb/pool.yaml). Wait for the controller before applying the pool: the pool is validated by MetalLB's webhook.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=180s
kubectl -n metallb-system get pods -o wide
kubectl apply -f components/metallb/pool.yaml
kubectl -n metallb-system get ipaddresspools,l2advertisements
```

Result (2026-11-05): controller and pool fine; the speaker on zangetsu in `CrashLoopBackOff`. Its log (`kubectl -n metallb-system logs <speaker-pod> --previous`) ends with:

```
failed to start metrics server: listen tcp 0.0.0.0:9120: bind: address already in use
```

The speaker runs with `hostNetwork`, so its metrics port competes with the host's ports. A Docker container on zangetsu publishes 9120, and another one on urahara publishes 9121. 7472 (MetalLB's old default) is free on both, so the speaker moves there:

```bash
sudo ss -tlnp | grep -E ':(9120|9121|7472) '    # on both nodes

kubectl -n metallb-system patch daemonset speaker --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"--port=7472"},
  {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":7472},
  {"op":"replace","path":"/spec/template/metadata/annotations/prometheus.io~1port","value":"7472"}
]'
kubectl -n metallb-system rollout status daemonset/speaker
```

Both speakers `1/1 Running`. This patch differs from the upstream manifest: re-applying the official file undoes it. In step 4 (GitOps) it becomes a Kustomize patch.

Lesson: every `hostNetwork` component needs a port check on every node before install. Ports used by MetalLB on the nodes: 7946 TCP/UDP (memberlist), 7472 (metrics), 17472 (health probe, localhost).

#### 1.15 LoadBalancer test and failover drill

A test Service with `type: LoadBalancer`:

```bash
kubectl create deployment lb-test --image=nginx:alpine --replicas=2
kubectl expose deployment lb-test --type=LoadBalancer --port=80
kubectl rollout status deployment/lb-test
kubectl get pods -l app=lb-test -o wide
kubectl get svc lb-test
kubectl get servicel2statuses -n metallb-system
curl -sI http://<FIRST_POOL_IP> | head -1
```

Result (2026-11-05): `EXTERNAL-IP` is the first IP of the pool, one nginx pod per node, `HTTP/1.1 200 OK`. zangetsu announces the IP.

Failover drill: a request loop on a PC on the LAN (PowerShell), then reboot the node that announces the IP.

```powershell
while ($true) { try { $r = Invoke-WebRequest http://<FIRST_POOL_IP> -TimeoutSec 2 -UseBasicParsing; "$(Get-Date -f HH:mm:ss) $($r.StatusCode)" } catch { "$(Get-Date -f HH:mm:ss) FAIL" }; Start-Sleep 1 }
```

```bash
kubectl drain zangetsu --ignore-daemonsets --delete-emptydir-data    # on urahara
sudo reboot                                                           # on zangetsu
kubectl get servicel2statuses -n metallb-system                       # on urahara, during the reboot
kubectl uncordon zangetsu                                             # on urahara, after the boot
```

First run: about 75 seconds of failed requests, and the IP never moved to urahara. kubeadm labels the control plane with `node.kubernetes.io/exclude-from-external-load-balancers`, and MetalLB does not announce from it (PM-0005). Fix (ADR 0013):

```bash
kubectl get node urahara --show-labels | tr ',' '\n' | grep exclude
kubectl label node urahara node.kubernetes.io/exclude-from-external-load-balancers-
```

Second run: urahara takes over the IP during the reboot, no failed requests.

#### 1.16 Storage: local-path-provisioner (ADR 0006)

Preflight on both nodes: free space on `/opt`, and the default volume directory does not exist yet.

```bash
df -h /opt
ls -ld /opt/local-path-provisioner 2>&1
```

Result (2026-11-06): 753 GB free on urahara, 355 GB on zangetsu; the directory does not exist on either node.

Install the latest release and make it the default StorageClass:

```bash
TAG=$(curl -s https://api.github.com/repos/rancher/local-path-provisioner/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4); echo "$TAG"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${TAG}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage rollout status deployment/local-path-provisioner
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass
```

Result: `v0.0.37`; `local-path (default)`, reclaim policy `Delete`, binding mode `WaitForFirstConsumer`, no volume expansion.

Test: a PVC and a pod that writes a file into it.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pv-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: pv-writer
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "date > /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pv-test
EOF
kubectl wait --for=condition=Ready pod/pv-writer --timeout=120s
kubectl get pvc pv-test
kubectl get pod pv-writer -o wide
kubectl exec pv-writer -- cat /data/hello.txt
```

Result: PVC `Bound` (100Mi, `local-path`), pod `Running` on urahara, the file has the date.

Persistence test: delete the pod and read the file from a new pod. A new reader pod, not the writer again, because the writer would overwrite the file.

```bash
kubectl describe pv "$(kubectl get pvc pv-test -o jsonpath='{.spec.volumeName}')" | grep -E -A4 'Node Affinity|Source'
sudo cat /opt/local-path-provisioner/*pv-test*/hello.txt

kubectl delete pod pv-writer
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pv-reader
spec:
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "cat /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pv-test
EOF
kubectl wait --for=condition=Ready pod/pv-reader --timeout=120s
kubectl get pod pv-reader -o wide
kubectl logs pv-reader
```

Result (2026-11-06): the PV has node affinity `kubernetes.io/hostname in [urahara]` and is a `HostPath` directory under `/opt/local-path-provisioner/`. The host sees the same file. `pv-reader` was scheduled on urahara without any node selector (the scheduler follows the PV's node affinity) and printed the same date as the writer. The data survived the pod.

Cleanup, and the `Delete` reclaim policy at work:

```bash
kubectl delete pod pv-reader
kubectl delete pvc pv-test
sleep 15
kubectl get pv
sudo ls /opt/local-path-provisioner/
```

Result: no PVs left and the directory is empty. Deleting the PVC deletes the data on disk. Database safety comes from replicas and backups (ADR 0006, ADR 0009), never from keeping a PVC.

The test LoadBalancer (`lb-test`) was removed too, which frees the first pool IP for the ingress controller.

#### 1.17 Traefik: Ingress and Gateway API (ADR 0008)

Lab DNS: a wildcard `*.lab.thalespm.me` pointing to the first MetalLB IP, set in the LAN's Pi-hole (`address=/lab.thalespm.me/<TRAEFIK_IP>` in `misc.dnsmasq_lines`). Check from any LAN client:

```bash
nslookup whoami.lab.thalespm.me
```

Helm, from the official apt repo:

```bash
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update && sudo apt-get install -y helm
helm version
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm show chart traefik/traefik | grep -E '^(version|appVersion)'
```

Result (2026-11-06): Helm v4.3.0; chart `42.3.1`, Traefik `v3.7.17`.

The first `helm install` failed with `no matches for kind "GatewayClass"`: the chart does not ship the Gateway API CRDs anymore. They are cluster-wide and shared by every controller, so they are installed once, on their own (standard channel, server-side apply because the CRDs are too large for the client-side annotation):

```bash
GWTAG=$(curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4); echo "$GWTAG"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWTAG}/standard-install.yaml"
kubectl get crd | grep gateway.networking.k8s.io
```

Then Traefik with [components/traefik/values.yaml](components/traefik/values.yaml) (fixed MetalLB IP, Ingress and Gateway API providers, default IngressClass, no chart-managed Gateway):

```bash
helm install traefik traefik/traefik -n traefik --create-namespace -f components/traefik/values.yaml
kubectl -n traefik rollout status deployment/traefik
kubectl -n traefik get pods,svc -o wide
kubectl get gatewayclass
curl -s -o /dev/null -w '%{http_code}\n' http://whoami.lab.thalespm.me
```

Result: Service `traefik` with the fixed IP on ports 80 and 443; GatewayClass `traefik` `ACCEPTED True`; `curl` returns `404` (Traefik answers, no route yet).

Gateway API version installed: `v1.7.0` (newer than the `v1.6.1` the chart notes mention; the `v1` API is backward compatible, and the Gateway below is `PROGRAMMED`).

```bash
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

Test app [components/traefik/whoami.yaml](components/traefik/whoami.yaml): the same Service exposed with an Ingress (`whoami.lab.thalespm.me`) and with a Gateway and HTTPRoute (`whoami-gw.lab.thalespm.me`). Applied straight from this repo:

```bash
kubectl apply -f https://raw.githubusercontent.com/thales-machado/platform-engineering-labs/main/k8s/local/components/traefik/whoami.yaml
kubectl -n whoami rollout status deployment/whoami
kubectl -n whoami get pods -o wide
kubectl -n whoami get ingress,httproute
kubectl -n traefik get gateway lab-gateway
curl -s http://whoami.lab.thalespm.me | head -6
curl -s http://whoami-gw.lab.thalespm.me | head -6
```

Result (2026-11-06): one whoami pod per node; Ingress and Gateway both on the Traefik IP; Gateway `PROGRAMMED True`; both hostnames answer over HTTP.

In the browser, `whoami.lab.thalespm.me` works but `whoami-gw.lab.thalespm.me` returns `404`. The browser upgrades to HTTPS (the whoami headers show `X-Forwarded-Proto: https`, port 443). An Ingress without TLS settings is served by every Traefik entry point, including `websecure` (443, Traefik's default self-signed certificate). An HTTPRoute is attached only to the listeners of its Gateway, and `lab-gateway` has only the HTTP listener (8000). So HTTPS requests to the Gateway hostname have no route. The fix is a real certificate and an HTTPS listener (next part).

Also visible in the headers: `X-Forwarded-For` / `X-Real-Ip` is the node IP, not the client's. With `externalTrafficPolicy: Cluster`, kube-proxy SNATs traffic that enters on one node and goes to a pod on another. Keeping the client IP needs `externalTrafficPolicy: Local`, which makes MetalLB announce only from nodes running a Traefik pod.

#### 1.18 HTTPS: cert-manager and a wildcard certificate

cert-manager with [components/cert-manager/values.yaml](components/cert-manager/values.yaml). The DNS-01 self-check uses public resolvers: the LAN's Pi-hole answers everything under `lab.thalespm.me` locally, so it would never return the `_acme-challenge` TXT record from Cloudflare.

```bash
helm show chart oci://quay.io/jetstack/charts/cert-manager | grep -E '^(version|appVersion)'
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager -n cert-manager --create-namespace -f components/cert-manager/values.yaml
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager get pods -o wide
```

Result (2026-11-06): cert-manager `v1.21.3`; controller, cainjector and webhook `Running`.

Cloudflare API token as a Secret, read without echo and kept out of shell history and Git. The lab reuses the homelab's DNS token for now. Better practice: a dedicated token for the lab (Zone DNS Edit and Zone Read, only the `thalespm.me` zone), so it can be revoked without touching the homelab.

```bash
read -rsp 'Cloudflare token: ' CF_TOKEN; echo
kubectl -n cert-manager create secret generic cloudflare-api-token --from-literal=api-token="$CF_TOKEN"
unset CF_TOKEN
kubectl -n cert-manager get secret cloudflare-api-token
```

ClusterIssuers for Let's Encrypt staging and production, from [components/cert-manager/cluster-issuers.yaml](components/cert-manager/cluster-issuers.yaml) (with the account email filled in), then the wildcard certificate, staging first to avoid production rate limits:

```bash
kubectl apply -f components/cert-manager/cluster-issuers.yaml
kubectl get clusterissuer
kubectl apply -f components/cert-manager/lab-wildcard-certificate.yaml     # with issuerRef letsencrypt-staging
kubectl -n traefik get certificate lab-wildcard -w
kubectl get challenges -A
```

Result (2026-11-06): both issuers `READY True`. The staging certificate for `lab.thalespm.me` and `*.lab.thalespm.me` was issued in 2m43s through a DNS-01 challenge in Cloudflare. The challenge resources are deleted after success, so `get challenges` is empty afterwards. Valid 90 days, renewal planned 30 days before expiry.

Switch to production, make the wildcard Traefik's default certificate, and add an HTTPS listener to the Gateway (port 8443, the `websecure` entry point). The HTTPRoute has no `sectionName`, so it attaches to both listeners.

```bash
kubectl apply -f components/cert-manager/lab-wildcard-certificate.yaml     # issuerRef letsencrypt-prod
kubectl -n traefik get certificate lab-wildcard -w
helm upgrade traefik traefik/traefik -n traefik -f components/traefik/values.yaml   # with tlsStore.default
kubectl -n traefik rollout status deployment/traefik
kubectl apply -f components/traefik/whoami.yaml                       # Gateway with the HTTPS listener
kubectl -n traefik get gateway lab-gateway

curl -s https://whoami.lab.thalespm.me | head -1
curl -s https://whoami-gw.lab.thalespm.me | head -1
echo | openssl s_client -connect <TRAEFIK_IP>:443 -servername whoami-gw.lab.thalespm.me 2>/dev/null | openssl x509 -noout -issuer -subject -enddate
```

Result (2026-11-06): both hostnames answer over HTTPS without `-k`. Certificate issuer `Let's Encrypt, CN=YR2` (production), subject `lab.thalespm.me`, valid until 2027-02-04. The Ingress and the Gateway both serve the wildcard. Decision record: ADR 0014.

#### 1.19 Kubelet serving certificates (ADR 0015)

metrics-server needs to verify each kubelet's certificate. kubeadm kubelets serve a self-signed one, so they request a certificate from the cluster CA instead.

Cluster-wide config, for nodes that join or upgrade later: in `kubectl -n kube-system edit configmap kubelet-config`, add `serverTLSBootstrap: true` right below `kind: KubeletConfiguration` (same indentation).

Each node's kubelet, on both nodes:

```bash
grep -q '^serverTLSBootstrap' /var/lib/kubelet/config.yaml || echo 'serverTLSBootstrap: true' | sudo tee -a /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
systemctl is-active kubelet
```

Approve the CSRs, after checking that the requestor is `system:node:<node>`:

```bash
kubectl get csr
kubectl certificate approve <csr-name> ...
echo | openssl s_client -connect <NODE_IP>:10250 2>/dev/null | openssl x509 -noout -issuer -subject
```

Result (2026-11-06): one CSR per kubelet restart (urahara had two, both harmless), all `Approved,Issued`. The first check showed zangetsu still self-signed (`issuer=CN=zangetsu-ca@...`): its kubelet had not been restarted with the new line. After the restart and approval, both nodes serve `issuer=CN=kubernetes`, `subject=O=system:nodes, CN=system:node:<node>`.

Approved CSR objects are cleaned up by the controller manager after about an hour. Deleting one (`kubectl delete csr <name>`) only removes the request object; the certificate already on the node stays valid.

#### 1.20 metrics-server

Official manifest, without `--kubelet-insecure-tls` (the kubelets serve certificates from the cluster CA, step 1.19):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server
kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
sleep 30
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -10
```

Result (2026-11-06): metrics-server `v0.9.1`, no TLS errors in its log. `kubectl top nodes`: urahara 4% CPU / 39% memory, zangetsu 29% CPU / 49% memory. The Raspberry Pi already runs at about half its memory with the homelab services, which supports keeping heavy workloads on urahara. The biggest pod is kube-apiserver (about 1 GiB).

#### 1.21 First app with Helm: our own chart

A chart written by hand, [charts/lab-app](charts/lab-app), for the podinfo image (`ghcr.io/stefanprodan/podinfo`, amd64 and arm64). It covers the workload topics of the CKA in one place:

| Template | What it practices |
|---|---|
| `configmap.yaml` | Non-secret settings, read as env vars (`envFrom`) |
| `secret.yaml` | A secret value, read with `secretKeyRef`; the real value comes from `--set`, never from Git |
| `deployment.yaml` | Liveness and readiness probes, requests and limits, non-root security context, read-only root filesystem, topology spread across nodes, checksum annotations that roll the pods when the ConfigMap or Secret changes |
| `service.yaml` | ClusterIP Service on port 80 |
| `httproute.yaml` | Route through the shared Gateway, HTTP and HTTPS |
| `hpa.yaml` | HorizontalPodAutoscaler on CPU (percent of the request), 2 to 6 replicas |
| `pdb.yaml` | PodDisruptionBudget, at least 1 pod during a drain |

The Deployment has no `replicas` when the HPA is on: the HPA owns the replica count, and a fixed number would fight it on every `helm upgrade`.

Install from a clone of this repo. Read the rendered YAML before touching the cluster, and pass the secret value without echo:

```bash
git clone https://github.com/thales-machado/platform-engineering-labs.git ~/platform-engineering-labs
cd ~/platform-engineering-labs/k8s/local/charts/lab-app
helm lint .
helm template lab-app . -n lab-app | less

read -rsp 'Demo API token: ' APP_TOKEN; echo
helm install lab-app . -n lab-app --create-namespace --set secret.apiToken="$APP_TOKEN"
unset APP_TOKEN
kubectl -n lab-app get deploy,pods,svc,hpa,pdb,httproute -o wide
curl -s https://app.lab.thalespm.me | head -5
```

Result (2026-11-06): the release installs; the Deployment starts with 1 pod and the HPA (`<unknown>` CPU for the first minute) takes it to 2. A `curl` in the first second returns Traefik's `no available server`: the route exists, but no pod is ready yet, so the readiness probe keeps it out of the Service. A few seconds later `https://app.lab.thalespm.me` shows the podinfo page with the message from the ConfigMap. The security context (non-root UID 1000, read-only root filesystem) works with the podinfo image.

HPA under load: a busybox pod with 20 loops calling the Service from inside the cluster, then the scale-down.

```bash
kubectl -n lab-app get hpa,pods -o wide
kubectl -n lab-app run load --image=busybox:1.36 --restart=Never -- /bin/sh -c 'for i in $(seq 1 20); do (while true; do wget -q -O- http://lab-app/ >/dev/null 2>&1; done) & done; wait'
kubectl -n lab-app get hpa -w
kubectl -n lab-app get pods -o wide
kubectl top pods -n lab-app
kubectl -n lab-app describe hpa lab-app | tail -10

kubectl -n lab-app delete pod load
kubectl -n lab-app get hpa -w
```

Result (2026-11-06): under load the HPA scaled to the maximum, 6 replicas. After the load pod was deleted, the reported CPU still rose for about a minute (117%, then 297%) before falling to 2%: metrics-server reports averages over its last scrape window, so the HPA sees the past, not the present. The replicas stayed at 6 for 5 minutes (the default scale-down stabilization window), then dropped to 5 and right after to 2 (the default scale-down policy allows removing up to 100% of the extra pods every 15 seconds).

Upgrade and rollback:

```bash
cd ~/platform-engineering-labs/k8s/local/charts/lab-app
helm upgrade lab-app . -n lab-app --reuse-values --set ui.message="Upgraded with Helm" --set ui.color="#6f2f4a"
kubectl -n lab-app rollout status deployment/lab-app
helm history lab-app -n lab-app
curl -s https://app.lab.thalespm.me | grep -E '"message"|"color"'

helm rollback lab-app 1 -n lab-app
kubectl -n lab-app rollout status deployment/lab-app
helm history lab-app -n lab-app
curl -s https://app.lab.thalespm.me | grep -E '"message"|"color"'
```

Result (2026-11-06): the upgrade only changed the ConfigMap, and the `checksum/config` annotation rolled the pods (revision 2). The rollback created revision 3, "Rollback to 1", with the original message: history is never rewritten.

Finding: the first `curl` right after `rollout status` returned the old message; a second `curl` returned the new one. `rollout status` reports done when the new pods are ready, but an old pod can still receive traffic for a few seconds while it terminates, until Traefik sees the updated endpoints. In production this shows up as old responses or 502s during deploys. The usual fix is a `preStop` sleep so the pod keeps serving until the endpoint change has propagated.

#### 1.22 CloudNativePG (ADR 0009)

Operator with Helm, and the `cnpg` kubectl plugin:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm show chart cnpg/cloudnative-pg | grep -E '^(version|appVersion)'
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
kubectl -n cnpg-system rollout status deployment/cnpg-cloudnative-pg
kubectl get crd | grep cnpg.io

curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin
kubectl cnpg version
```

Result (2026-11-09): chart `0.29.1`, operator `1.30.1`, 11 CRDs (`clusters`, `backups`, `scheduledbackups`, `poolers`, `databases` and others). Plugin `1.30.1`.

PostgreSQL cluster from [components/postgres/cluster.yaml](components/postgres/cluster.yaml): two instances with required anti-affinity (one per node), 2 GiB local-path volumes, small resources for the Raspberry Pi, and a database and owner `app` created at bootstrap.

```bash
kubectl apply -f components/postgres/cluster.yaml
kubectl -n lab-db get cluster lab-pg -w
kubectl -n lab-db get pods,pvc -o wide
kubectl cnpg status lab-pg -n lab-db
```

Result: PostgreSQL `18.6` (image `ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie`), `Cluster in healthy state`. Primary `lab-pg-1` on urahara, standby `lab-pg-2` on zangetsu, each with its own `Bound` PVC. Streaming replication, asynchronous, with a replication slot; zero lag. No continuous backup configured yet.

Failover drill: [components/postgres/writer.yaml](components/postgres/writer.yaml) inserts one row per second through the read-write Service (`lab-pg-rw`, always the current primary), with the URI from the operator-generated Secret. Kill the primary while it writes:

```bash
kubectl apply -f components/postgres/writer.yaml
kubectl -n lab-db logs -f pg-writer           # wait for steady "ok" lines
kubectl -n lab-db delete pod <primary-pod>    # second terminal
kubectl cnpg status lab-pg -n lab-db
kubectl cnpg psql lab-pg -n lab-db -- -d app -c "select pod, count(*), min(at), max(at) from drill group by pod order by min(at);"
kubectl -n lab-db logs pg-writer | grep -B2 -A2 FAIL
```

First run: the primary was deleted while the writer was still starting, so the writer only saw the new primary. The failover itself worked: `lab-pg-2` promoted 4 seconds after the delete (timeline 1 to 2), and `lab-pg-1` came back on its PVC as a standby in about 11 seconds.

Second run (2026-11-09), primary `lab-pg-2` on zangetsu deleted at about 19:45:23 UTC:

| Time (UTC) | Writer | Cluster |
|---|---|---|
| 19:45:23 | last `ok` on zangetsu | primary pod deleted |
| 19:45:24 to 19:45:26 | 3 `FAIL` | no primary |
| 19:45:27 | `ok` again, now on urahara | `lab-pg-1` promoted, timeline 3 |

Write downtime: about 3 seconds. Rows grouped by server: 278 on the old primary, then the new primary from 19:45:27. Every committed row survived. Right after the promotion, `cnpg status` shows the deleted instance as `InternalError` / `the database system is starting up` while it comes back as a standby.

Side finding: `kubectl logs -f` stopped with `failed to create fsnotify watcher: too many open files`. urahara hit the default inotify instance limit (Docker containers plus Kubernetes pods). Raised on both nodes:

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-inotify.conf
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches   = 524288
EOF
sudo sysctl --system | grep inotify
```

#### 1.23 Upgrade to 1.37 (ADR 0010)

Order: etcd backup, control plane on urahara, then each node with drain and uncordon. The CNPG primary moves off a node before that node is drained.

Backup first, on urahara:

```bash
sudo mkdir -p /var/backups/etcd
kubectl -n kube-system exec etcd-urahara -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-pre-1.37.db
sudo mv /var/lib/etcd/snapshot-pre-1.37.db /var/backups/etcd/
sudo ls -lh /var/backups/etcd/
```

Result (2026-11-09): `snapshot-pre-1.37.db`, 18 MB.

Repo switch, on each node before its upgrade:

```bash
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring-1.37.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring-1.37.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
apt-cache madison kubeadm | head -3
```

Latest patch: `1.37.2-1.1`.

Control plane, on urahara:

```bash
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.37.2-1.1
sudo apt-mark hold kubeadm
sudo kubeadm upgrade plan
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:'
sudo kubeadm upgrade apply v1.37.2
```

`upgrade plan`: API server, controller-manager, scheduler and kube-proxy 1.36.6 to 1.37.2, CoreDNS v1.14.2 to v1.14.6, etcd 3.6.8-0 to 3.7.0-0. No component config needs a manual upgrade (`kubeproxy.config.k8s.io` and `kubelet.config.k8s.io` both `no`). `upgrade apply` ended with `SUCCESS`. kube-proxy stayed in `nftables` mode: kubeadm rewrote the ConfigMap from the values already in the cluster.

Right after `apply`, the node list still shows 1.36.6: the VERSION column is the kubelet. Both new CoreDNS pods were scheduled on zangetsu, because the old CoreDNS pod was still on urahara and kubeadm's CoreDNS only has a preferred anti-affinity.

urahara kubelet: switchover first, then drain.

```bash
kubectl cnpg promote lab-pg lab-pg-2 -n lab-db
kubectl drain urahara --ignore-daemonsets --delete-emptydir-data
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.37.2-1.1 kubectl=1.37.2-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon urahara
```

On the first control plane node, `upgrade apply` already updated the kubelet config, so `kubeadm upgrade node` is not needed there. The switchover promoted `lab-pg-2` on zangetsu (timeline 4). During the drain, `lab-pg-1` stayed `Pending`: its PVC is a local-path volume on urahara, and urahara was cordoned. After the uncordon it came back as a streaming standby with zero lag in under 4 minutes.

zangetsu: switchover back, spread CoreDNS, drain, upgrade on the node, uncordon.

```bash
kubectl cnpg promote lab-pg lab-pg-1 -n lab-db
kubectl -n kube-system rollout restart deployment coredns
kubectl drain zangetsu --ignore-daemonsets --delete-emptydir-data

# on zangetsu
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.37.2-1.1
sudo apt-mark hold kubeadm
sudo kubeadm upgrade node
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.37.2-1.1 kubectl=1.37.2-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# on urahara
kubectl uncordon zangetsu
```

The CoreDNS restart avoids a DNS outage: kubeadm creates no PDB for CoreDNS, so a drain of the node with both replicas evicts them at the same time.

Checks:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -v Running
kubectl cnpg status lab-pg -n lab-db
kubectl get nodes urahara --show-labels | tr ',' '\n' | grep exclude || echo "label still removed"
curl -sk https://app.lab.thalespm.me/healthz
```

Result (2026-11-09): both nodes `Ready` on `v1.37.2`, no pod outside `Running`. PostgreSQL healthy with primary `lab-pg-1` on urahara (timeline 5) and `lab-pg-2` streaming with zero lag. The `exclude-from-external-load-balancers` label did not come back (ADR 0013). The app answered `{"status": "OK"}`.

Follow-ups:
- Traefik runs with one replica, so a drain of its node stops HTTPS for a few seconds. Two replicas and a PDB.
- A PDB for CoreDNS, or the restart step above, in every future node maintenance.

### 2. Observability

Done (2026-11-11 to 2026-11-14). Scope and order were set by [PM-0006](docs/postmortems/0006-etcd-crash-corrupted-image-layer.md), the 41 hour outage nobody noticed, so the work started outside the cluster and moved inwards:

#### 2.1 Kubernetes Dashboard, read-only (2026-11-11)

A web UI before the metrics stack, to see the cluster while the rest of step 2 is built. The project is retired, so the chart comes from the archived repository; the docs on kubernetes.io still point at the old URL, which now returns 404.

```bash
helm repo add kubernetes-dashboard https://kubernetes-retired.github.io/dashboard/
helm repo update kubernetes-dashboard
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --version 7.14.0 \
  --namespace kubernetes-dashboard --create-namespace \
  -f components/dashboard/values.yaml
kubectl apply -f components/dashboard/rbac.yaml
kubectl apply -f components/dashboard/route.yaml
kubectl -n kubernetes-dashboard get secret dashboard-viewer-token -o jsonpath='{.data.token}' | base64 -d; echo
```

Chart 7.x is five pods, including its own Kong proxy. TLS and routing stay with the shared Gateway: the chart's ingress is disabled, Kong listens on plain HTTP inside the cluster (`kong.proxy.http.enabled`), and an HTTPRoute sends `dashboard.lab.thalespm.me` to `kubernetes-dashboard-kong-proxy:80`. The Pi-hole wildcard already resolves the hostname, so no DNS change was needed.

Access is a ServiceAccount token, read-only by choice: the built-in `view` ClusterRole plus a small ClusterRole for the cluster-scoped objects the UI draws (nodes, PVs, storage classes, CRDs, metrics). `view` excludes Secrets, so the Dashboard shows them as forbidden. Changing the cluster stays with `kubectl`.

The token Secret is of type `kubernetes.io/service-account-token`, because `kubectl create token` issues one that expires in an hour.

#### 2.2 External probes (2026-11-11)

The control plane was down for 41 hours and nothing noticed. An Alertmanager inside the cluster would have been down with it, so availability of the cluster is watched from outside, by the monitoring stack that already runs on the homelab host: VictoriaMetrics for scraping, Grafana for alerting, blackbox-exporter for the probes. The configuration lives in the homelab repository; [monitoring/external/](monitoring/external/) lists where each piece goes.

A blackbox module with `insecure_skip_verify` is needed for the API server, whose certificate is signed by the cluster CA. `/healthz`, `/livez`, `/readyz` and `/version` allow anonymous access on a kubeadm cluster, so the probe needs no credentials.

```bash
# from the homelab host, before wiring the alert
docker run --rm --network <net> curlimages/curl -s \
  'http://blackbox-exporter:9115/probe?module=http_2xx_insecure&target=https://<URAHARA_IP>:6443/readyz' \
  | grep -E '^probe_success|^probe_http_status_code'
```

Two alerts, both `for: 2m` and `noDataState: Alerting`, because no data from the probe is itself the failure: one on `/readyz`, one on the app through the Ingress. Separating them answers the question that was invisible during PM-0006, whether the control plane is down or the app is.

Verified by stopping `kube-apiserver.yaml` for three minutes: the alert arrived on the phone in about two minutes, and resolved when the manifest came back. Pods and the app were untouched the whole time.

Testing the alert end to end found two defects in the homelab that had nothing to do with this lab, and both had been silent for a long time:

- The Grafana webhook built its JSON by hand and interpolated the alert summary raw. Two rules quoted the container name, so their payload was invalid and the webhook answered `400`. Those alerts had never been delivered.
- `GRAFANA_ALERT_WHATSAPP_JID` was in `.env.example` but never set on the host, so the destination was empty. No Grafana alert had ever reached anyone.

The lesson is older than this lab: an alert nobody has watched fire is a guess, not a safeguard.

#### 2.3 In-cluster stack (2026-11-12, [ADR 0016](docs/adr/0016-in-cluster-observability-stack.md))

kube-prometheus-stack for metrics, Loki for logs, Alloy as the log agent. Prometheus, Grafana and Loki are pinned to urahara with local-path volumes; zangetsu runs only the per-node agents, node-exporter and Alloy.

Alertmanager is disabled. Alerting lives outside the cluster (2.2), where it survives the cluster being down, and two alerting systems that can both page are worse than one.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace lab-obs
read -rsp 'Grafana admin password: ' PW; echo
kubectl -n lab-obs create secret generic grafana-admin \
  --from-literal=admin-user=keydrop --from-literal=admin-password="$PW"
unset PW

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 93.2.2 -n lab-obs -f components/observability/kube-prometheus-stack-values.yaml
helm upgrade --install loki grafana/loki \
  --version 7.6.0 -n lab-obs -f components/observability/loki-values.yaml
helm upgrade --install alloy grafana/alloy \
  --version 1.15.0 -n lab-obs -f components/observability/alloy-values.yaml
kubectl apply -f components/observability/grafana-route.yaml
```

The password is read with `read -rsp` so it never reaches the shell history, and Grafana reads it from the Secret through `admin.existingSecret`. Grafana creates the admin user only on its first start: if the PVC already holds a database, changing the Secret does nothing until the PVC is deleted.

Loki runs as `SingleBinary` with filesystem storage and replication factor 1. Retention needs three settings together, and two of them are easy to miss: `limits_config.retention_period`, `compactor.retention_enabled: true` and `compactor.delete_request_store`. Without the compactor part, old data is hidden from queries but never deleted from disk.

Four things only showed up when the stack was running:

- node-exporter crashed on urahara with `address already in use`. The homelab runs its own node-exporter in Docker on 9100 on the same machine. The in-cluster one moved to 9101; the homelab keeps 9100.
- Prometheus and Loki use distroless images, so `kubectl exec ... wget` or `cat` fails with `executable file not found`. Query the HTTP API through a port-forward, or read the rendered config from the ConfigMap or Secret the chart created.
- Both Alloy pods were tailing all 47 containers in the cluster, not just their own node. `discovery.kubernetes` with `role = "pod"` lists the whole cluster unless a field selector narrows it: `field = "spec.nodeName=" + sys.env("NODE_NAME")`, with `NODE_NAME` from `fieldRef`. Every log line was being read twice through the API server.
- The `node` label was always empty. For `role = "pod"` the meta label is `__meta_kubernetes_pod_node_name`; `__meta_kubernetes_node_name` only exists for `role = "node"`.

The app itself was silent in Loki. podinfo logs one line per HTTP request only at debug level, so the chart gained a `logLevel` value, set to `debug` here. Almost every line is a probe on `/readyz` and `/healthz`, which is honest traffic for a lab with no users and good material for LogQL filtering later.

```bash
kubectl -n lab-obs port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' | python3 -c "
import sys,json,collections
d=json.load(sys.stdin)
c=collections.Counter((t['labels'].get('job'),t['health']) for t in d['data']['activeTargets'])
[print(f'{h:8} {j}  x{n}') for (j,h),n in sorted(c.items())]"
```

Result (2026-11-12): 16 active targets, all `up` (apiserver, coredns, kubelet, kube-state-metrics, node-exporter, grafana, operator, prometheus). Loki holds seven labels and eleven namespaces, and `{namespace="lab-app"}` returns the request log. The control plane components are still invisible on purpose; they come in 2.4.

#### 2.4 Control plane metrics and the alerts the postmortems asked for

kubeadm binds etcd, the scheduler, the controller-manager and kube-proxy to `127.0.0.1`, so a Prometheus running in a pod cannot reach any of them. Each one was opened in its own round, with a check in between, because PM-0006 started with a change to a control plane static pod.

| Component | Where the address lives | From | To |
|---|---|---|---|
| kube-scheduler | `/etc/kubernetes/manifests/kube-scheduler.yaml`, `--bind-address` | `127.0.0.1` | `0.0.0.0`, port 10259 |
| kube-controller-manager | `/etc/kubernetes/manifests/kube-controller-manager.yaml`, `--bind-address` | `127.0.0.1` | `0.0.0.0`, port 10257 |
| kube-proxy | ConfigMap `kube-system/kube-proxy`, `metricsBindAddress` | `""` | `0.0.0.0:10249` |
| etcd | `/etc/kubernetes/manifests/etcd.yaml`, `--listen-metrics-urls` | `http://127.0.0.1:2381` | `http://0.0.0.0:2381` |

The scheduler and the controller-manager still demand a bearer token, so a browser gets `403 system:anonymous`, which is the proof that the port is open and authentication works. kube-proxy on 10249 and etcd on 2381 are plain HTTP with no authentication; etcd's 2381 serves `/metrics` and `/health` only, and the key-value API stays on 2379 behind client certificates.

Two traps, both costing a round:

- Editing a static pod manifest replaces the pod, so the API server refuses connections for a few seconds. `kubectl` fails with `TLS handshake timeout` and the cluster is fine. Check etcd with `crictl` instead of waiting on `kubectl`.
- A mounted ConfigMap updates on the kubelet's sync loop, up to about a minute. Restarting kube-proxy immediately after `kubectl apply` gives the pods the old file. The second restart is the one that works.

Before touching etcd, a snapshot, taken from inside the container because `etcdctl` is not on the host:

```bash
kubectl -n kube-system exec etcd-urahara -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-$(date +%Y%m%d-%H%M).db
```

Result (2026-11-12): 21 targets, all `up`. etcd logged `initial corruption checking passed` on restart, which checks the database and not the binary, so it would not have caught PM-0006.

These four addresses live on the node, not in this repository. A `kubeadm init` on a rebuilt urahara puts them back on `127.0.0.1` and the targets go down.

Alerting stays outside the cluster, for the reason in 2.2. The homelab Grafana reads in-cluster Prometheus as a second datasource, through [components/observability/prometheus-route.yaml](components/observability/prometheus-route.yaml): the Prometheus API has no authentication of its own, so a Traefik basic-auth middleware sits in front of it, attached to the HTTPRoute with an `ExtensionRef` filter.

Eight rules, all with the label `shortname: K8SLAB`, all delivered to WhatsApp through the contact point that 2.2 proved works:

| Rule | Query | Fires | From |
|---|---|---|---|
| API server unreachable | `probe_success{job="blackbox-k8s-lab"}` | < 1 for 2m | PM-0006 |
| App not answering | `probe_success` on the public health endpoint | < 1 for 2m | 2.2 |
| Control plane container restarted | restarts of etcd, apiserver, controller-manager, scheduler in 15min | > 0 for 5m | PM-0006 |
| Node not Ready | `kube_node_status_condition` | < 1 for 5m | general |
| Pod in CrashLoopBackOff | `kube_pod_container_status_waiting_reason` | > 0 for 10m | PM-0001 |
| calico-node restarting | restarts in `calico-system` in 30min | > 2 for 5m | PM-0002 |
| LoadBalancer IP not announced | `sum(metallb_speaker_announced) or vector(0)` | < 1 for 5m | PM-0005 |
| Cross-node traffic failing | `min(probe_success{path="cross-node"})` | < 1 for 3m | PM-0003 |

Two of them needed something built before a rule was possible.

**MetalLB (PM-0005)** came from the upstream manifest, which creates no scrape config, so [components/metallb/podmonitor.yaml](components/metallb/podmonitor.yaml) adds a `PodMonitor`. Port 7472 serves TLS with delegated authentication: plain HTTP answers `400` and an unauthenticated request answers `401`, so the scrape carries a ServiceAccount token from a Secret, because a `PodMonitor` endpoint cannot read the token from the pod's own filesystem the way a `ServiceMonitor` can. That still answered `500`, and the speaker's log said why: `metallb-native.yaml` ships no binding for `tokenreviews`, so MetalLB cannot validate the token it is given. Its Helm chart creates that binding; the plain manifest does not. [components/metallb/metrics-rbac.yaml](components/metallb/metrics-rbac.yaml) binds `system:auth-delegator` to both ServiceAccounts. The useful metric is `metallb_speaker_announced`, one series per LoadBalancer Service with the announcing node.

**Pod-to-pod traffic (PM-0003)** had no signal at all. Calico broke east-west traffic while both nodes reported Ready and every pod kept running, so nothing noticed. [components/netcheck/](components/netcheck/) pins one target to each node behind its own ClusterIP and runs a blackbox-exporter on urahara that probes both. Traffic to the Service whose only endpoint sits on zangetsu crosses the CNI; the probe to the local one is the control:

| cross-node | same-node | meaning |
|---|---|---|
| fail | pass | the network between the nodes |
| fail | fail | the exporter or the whole cluster |
| pass | fail | that one target pod |

Result (2026-11-14): both probes `1`, MetalLB targets `up`, eight rules loaded and Normal.

Drill, same day: `kubectl -n lab-obs scale deploy/netcheck-zangetsu --replicas=0` at 08:54:13, back at 09:04:23. During those ten minutes `probe_success` read `cross-node 0` and `same-node 1`, which is the signature of a network failure rather than a dead workload. Scaling to zero rather than deleting the pod is deliberate: a deleted pod returns in seconds and never reaches the three-minute threshold.

| Time | Event |
|---|---|
| 08:54:13 | target scaled to zero |
| 08:57:43 | rule fires, exactly `for: 3m` later |
| 08:58 | WhatsApp alert |
| 09:04:23 | target back |
| 09:08 | WhatsApp resolved |

Reading the Grafana log alone was misleading: `Sending alerts to local notifier` is printed for resolved alerts as well as firing ones, so the line repeating after recovery looked like an alert stuck on. The phone is the only place that answers the question the alert exists to answer.

With this, every postmortem action that was waiting on step 2 is closed, except `tigerastatus`, which has no metric: the Tigera operator publishes it as a CRD only.

#### 2.5 Integrity check of unpacked image layers (2026-11-14)

containerd verifies the digest of the compressed blob it downloads and never the file it extracted, while the kubelet executes the extracted file. PM-0006 was exactly that gap: a corrupted etcd binary, same size, different sha256, crashing with SIGSEGV while the running process carried on from page cache.

[scripts/check-image-binaries.sh](scripts/check-image-binaries.sh) hashes each control plane binary through `/proc/<pid>/exe` and compares it with a baseline. Reading through `/proc` matters twice over: it is the exact file the process is executing, whatever the image layout, and it reads the file on disk rather than the copy in memory the process is living on.

```bash
sudo install -m 0755 scripts/check-image-binaries.sh /usr/local/sbin/
sudo install -m 0644 scripts/check-image-binaries.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now check-image-binaries.timer
sudo /usr/local/sbin/check-image-binaries.sh --update   # after any image upgrade
```

The result is a metric rather than an email: the script writes `lab_binary_integrity` into node-exporter's textfile directory, the homelab node-exporter picks it up on the next scrape, and two rules in the homelab Grafana watch it. The homelab exporter rather than the in-cluster one, deliberately: the failure this exists for took the cluster down for 41 hours, and a metric living inside that cluster would have gone down with it.

| Rule | Query | Fires |
|---|---|---|
| binary differs from baseline | `lab_binary_integrity` | < 1 for 10m, critical |
| check has not run | `time() - lab_binary_check_timestamp_seconds` | > 8 days, warning |

The second rule matters more than it looks. A textfile metric keeps serving its last value forever, so a dead timer and a healthy one are indistinguishable without a timestamp.

Result (2026-11-14): six binaries on urahara (etcd, kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, calico-node) and two on zangetsu, all matching, all eight series in VictoriaMetrics.

Three things went wrong while building it, and all three are worth keeping:

- The first version mapped each container to a hardcoded binary path. `calico-node` has no binary at the obvious path, and keeping such a map in step with upstream images is work with no payoff. `/proc/<pid>/exe` removes the map entirely.
- On a node without `crictl` the script found no containers and still wrote a metrics file full of nothing, which reads as "all good" on a dashboard. A check that verifies nothing now fails instead. That is the same class of bug as the alert that never fired in 2.2.
- `crictl` was installed on urahara during PM-0006 and never on zangetsu, which is why that was found at all.

What this does not do: it detects corruption and accidental drift, not tampering. Anything that can rewrite the binary can rewrite the baseline next to it. Verifying the extracted file against the image layer it came from would close that, and it stays open.

#### 2.6 Drills

**Drain a node while the database is being written to (2026-11-14).** [components/postgres/writer.yaml](components/postgres/writer.yaml) inserts one row per second through `lab-pg-rw` and records `inet_server_addr()`, so the switchover is visible in the data and not only in the logs.

zangetsu is the node to drain, not urahara: Prometheus, Grafana and Loki are pinned to urahara with `local-path` volumes, which are node-bound, so draining urahara would leave them Pending and blind the dashboards the drill is meant to be watched on. The primary was moved to zangetsu first with `kubectl cnpg promote`, which cost 9 seconds of writes.

Two things the drill found:

- **CloudNativePG switches over on the cordon, not on the eviction.** The first `drain` aborted immediately (`cannot delete Pods that declare no controller: lab-db/pg-writer`) but the cordon had already applied, and CNPG moved the primary anyway: `Switching over to lab-pg-1, because primary instance was running on unschedulable node zangetsu`. 8 seconds of writes lost, with no drain command still running. The PDB is a safety net here, not the trigger.
- **A bare Pod blocks a drain.** `pg-writer` has no controller, so `drain` refuses to evict it and stops. It is now pinned to urahara; the observer must never sit on the node being drained.

With the primary already moved, the real drain took 7 seconds and the writer never left `ok`. Losing the standby costs nothing.

```sql
select prev::time, at::time, at - prev as gap
from (select at, lag(at) over (order by at) prev from drill) t
where at - prev > interval '2 seconds' order by at;
```

Result: gaps of 9s (manual promote), 8s (cordon switchover) and 3s (the writer pod being recreated by hand), and nothing at all during the drain window. Every gap is explained; no write was lost.

`lab-pg-2` stayed Pending while the node was cordoned, because its `local-path` volume exists only on zangetsu. With node-bound storage, a node down means a database with no replica, not a database that moved.

The cross-node probe went red during the drain and no alert fired, which is correct: the pod was Pending for about 65 seconds, under the 3 minute threshold. Short planned maintenance stays quiet.

**Restore an etcd snapshot (2026-11-14).** Snapshots have been taken before every upgrade and never opened, which makes them an assumption rather than a backup. [drills/etcd-restore-check.yaml](drills/etcd-restore-check.yaml) opens the newest one without touching the cluster: `/var/lib/etcd` mounted read-only, the restore written to an `emptyDir`, and a second etcd listening on loopback inside the pod's own network namespace.

```bash
kubectl apply -f drills/etcd-restore-check.yaml
kubectl -n kube-system logs etcd-restore-check -c status
kubectl -n kube-system exec etcd-restore-check -- etcdctl \
  --endpoints http://127.0.0.1:2399 get /registry/namespaces --prefix --keys-only
kubectl -n kube-system delete pod etcd-restore-check
```

Result: hash `5609f790`, revision 1099089, 1224 keys, 37 MB, and all 16 namespaces read back out of the restored copy.

Two things the drill taught, both about the tools rather than the backup:

- `etcdctl snapshot restore` no longer exists. etcd 3.6 moved it to `etcdutl`, so most of what you find written about this online fails on this cluster.
- The etcd image is distroless. The first version of this drill was one shell script and never started: `exec: "/bin/sh": no such file or directory`. Each step now runs a binary directly, with busybox doing the only part that needs a shell. That is the third distroless image in step 2 after Prometheus and Loki; `exec ... sh`, `wget` and `cat` are gone from most official images now.

### 3. SLI, SLO and error budget

Planned.

### 4. GitOps and progressive delivery

Planned.

### 5. CNI migration: Calico to Cilium

Planned.

## Postmortems

| ID | Date | Title | Severity |
|---|---|---|---|
| [PM-0001](docs/postmortems/0001-crowdsec-restart-after-node-reboot.md) | 2026-11-05 | CrowdSec restarted on urahara after zangetsu reboot | low |
| [PM-0002](docs/postmortems/0002-calico-node-crash-nftables-rules.md) | 2026-11-05 | calico-node crash loop on zangetsu (incompatible nftables rules) | medium |
| [PM-0003](docs/postmortems/0003-pod-traffic-dropped-by-docker-forward.md) | 2026-11-05 | Pod traffic between nodes dropped by Docker's FORWARD policy | medium |
| [PM-0004](docs/postmortems/0004-swap-back-after-reboot.md) | 2026-11-05 | Swap came back on urahara after reboot, kubelet down | medium |
| [PM-0005](docs/postmortems/0005-no-lb-failover-control-plane-excluded.md) | 2026-11-05 | No LoadBalancer failover when zangetsu rebooted | medium |
| [PM-0006](docs/postmortems/0006-etcd-crash-corrupted-image-layer.md) | 2026-11-09 | etcd crash loop from a corrupted image layer on disk, control plane down 41h | high |

## Teardown

Filled in when step 1 installs the cluster.

## Lessons learned

None yet.
