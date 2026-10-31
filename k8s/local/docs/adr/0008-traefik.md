# 0008. Traefik as Ingress and Gateway API controller

- Status: accepted
- Date: 2026-10-31

## Context

The lab needs HTTP routing. ingress-nginx was retired by the Kubernetes project in March 2026 and gets no more fixes. The CKA still covers the Ingress API, and Gateway API is the newer standard.

## Options

- **ingress-nginx**: retired.
- **Traefik**: supports both Ingress and Gateway API, multi-arch images.
- **Envoy Gateway**: Gateway API only.
- **Cilium Gateway**: only after step 5.

## Decision

Traefik, installed with Helm, exposed through a MetalLB VIP (0005).

## Consequences

- One controller covers both APIs: classic Ingress for CKA practice and Gateway API for current practice.
- After step 5, compare with Cilium Gateway in a new ADR.
