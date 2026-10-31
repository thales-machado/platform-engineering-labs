# 0004. Calico first, migrate to Cilium in step 5

- Status: accepted
- Date: 2026-10-31

## Context

The cluster needs a CNI. The LAN is a /24 inside `192.168.0.0/16`, and Docker uses `172.17.0.0/16` plus Compose networks.

## Options

- **Calico**: mature, iptables or eBPF, NetworkPolicy, widely used.
- **Cilium**: eBPF, can replace kube-proxy, has LB IPAM, L2 announcements, Gateway API and Hubble.
- **Calico first, then a live migration to Cilium**.

## Decision

Calico in step 1 with kube-proxy. In step 5, migrate to Cilium on the running cluster with Cilium's per-node migration.

## Consequences

- Pod CIDR `10.244.0.0/16` for Calico and `10.245.0.0/16` for Cilium. The migration needs two CIDRs, and Calico's default `192.168.0.0/16` would overlap the LAN.
- Service CIDR stays at the kubeadm default `10.96.0.0/12`.
- The migration is a real operation with risk, so it gets a runbook and a postmortem if something breaks.
- After the migration, Cilium can replace kube-proxy and MetalLB (see 0005), and Hubble adds network flows to step 2.
