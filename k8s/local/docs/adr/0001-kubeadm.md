# 0001. Build the cluster with kubeadm

- Status: accepted
- Date: 2026-10-31

## Context

The lab covers the "Kubernetes in production" gap and is CKA preparation. It runs on two homelab servers: one amd64 and one arm64.

## Options

- **minikube / kind**: whole cluster inside one host, often inside containers. Very easy, but no real nodes, no real network between hosts and no control plane work.
- **k3s**: one binary, fast install, light on a Raspberry Pi. It bundles Flannel, Traefik, ServiceLB and local-path, and uses SQLite by default, so many choices are made for you.
- **kubeadm**: upstream tool. Each part is installed by hand: runtime, control plane, CNI, ingress, storage.

## Decision

kubeadm.

## Consequences

- More setup work, and every component is a choice that gets its own ADR.
- Matches the CKA exam: `kubeadm init/join/upgrade`, certificates, etcd backup and restore.
- Upgrades and certificate renewal are our job. They become drills.
