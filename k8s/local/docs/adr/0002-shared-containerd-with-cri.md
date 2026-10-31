# 0002. Use Docker's containerd with the CRI plugin enabled

- Status: accepted
- Date: 2026-10-31

## Context

Both servers run homelab services with Docker. Docker ships `containerd.io`, with `disabled_plugins = ["cri"]` in `/etc/containerd/config.toml`. Kubelet needs a CRI runtime. Versions found: containerd 2.3.3 on urahara and 2.2.6 on zangetsu, cgroup v2 on both.

## Options

- **Enable CRI in Docker's containerd**: one daemon, one socket.
- **Second containerd for Kubernetes**: separate daemon, socket, config and state directory.
- **cri-dockerd**: kubelet talks to Docker through a shim. Extra component, and it is not the common path.

## Decision

Enable CRI in the existing containerd, with `SystemdCgroup = true`.

## Consequences

- Docker and Kubernetes share the daemon but use different namespaces (`moby` and `k8s.io`), so they do not see each other's containers.
- A containerd restart touches homelab containers. Back up `config.toml` first and do it in a quiet moment.
- An `apt upgrade` of `containerd.io` also upgrades the Kubernetes runtime. Pin it with `apt-mark hold` and upgrade on purpose.
- The two nodes run different containerd minor versions. Align them before `kubeadm init`.
