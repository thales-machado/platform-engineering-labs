# 0003. Multi-arch images by default, node affinity when needed

- Status: accepted
- Date: 2026-10-31

## Context

urahara is amd64 and zangetsu is arm64. A pod scheduled on a node without an image for its architecture fails with `exec format error`.

## Options

- **Multi-arch images only**: every image must have amd64 and arm64.
- **Pin everything to one architecture with node affinity**: simple, but the second node is wasted.
- **Multi-arch by default, affinity as the exception**.

## Decision

Multi-arch by default. When an image is amd64-only, pin it with `nodeAffinity` on `kubernetes.io/arch`.

## Consequences

- Check the image manifest (`docker manifest inspect` or `crane manifest`) before using a new image.
- The lab's own sample app is built for both architectures with `docker buildx`.
- A wrong-architecture pod is a good drill.
