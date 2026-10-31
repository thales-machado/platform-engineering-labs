# 0005. MetalLB in L2 mode for LoadBalancer IPs

- Status: accepted
- Date: 2026-10-31

## Context

Ports 80 and 443 on both servers are already used by homelab services. Bare metal has no cloud load balancer. urahara has a second NIC; zangetsu has only one.

## Options

- **NodePort**: ports 30000-32767, no extra component, ugly URLs, not how production exposes traffic.
- **hostNetwork / hostPort**: conflicts with the homelab on 80 and 443.
- **MetalLB L2**: answers ARP for free LAN IPs and sends traffic to the Service.
- **MetalLB on the second NIC only**: works only on urahara and adds routing complexity.

## Decision

MetalLB L2 with a small pool of fixed LAN IPs outside the router's DHCP range.

## Consequences

- The homelab keeps the host IPs on 80 and 443. The ingress controller gets a VIP on the same ports. No conflict.
- One node answers ARP for each VIP. If that node fails, another takes over after a short gap. Good drill.
- The pool must stay out of DHCP and out of any fixed IP on the LAN.
- In step 5, Cilium LB IPAM and L2 announcements can replace it.
