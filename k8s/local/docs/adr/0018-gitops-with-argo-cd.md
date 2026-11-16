# 0018. GitOps with Argo CD, adopted one component at a time

- Status: accepted
- Date: 2026-11-16

## Context

Steps 1 and 2 installed everything by hand: `helm upgrade --install` for eight charts and `kubectl apply` for a dozen manifests. The repository already holds every values file and manifest, so the desired state is written down, but nothing enforces it. A change made directly in the cluster stays there, and the only way to know is to remember.

Step 4 is GitOps. The cluster should converge on what the repository says, and a drift should be visible rather than discovered during an incident.

The target roles name Argo specifically: Argo CD for GitOps and Argo Rollouts for progressive delivery, which connects to the API Gateway canary work already in the portfolio.

## Options

- **Flux**: lighter, no UI, Kustomize and Helm controllers, fits a small cluster well. Less visible in job descriptions, and its canary story is Flagger, which is a separate project.
- **Argo CD**: heavier (seven workloads), a UI that shows drift and sync state, and Argo Rollouts from the same family for canary with automated analysis.
- **Keep installing by hand**: honest for a lab of this size, and it is what step 1 and 2 did. It fails the point of the step.

## Decision

Argo CD, chart 10.18.0 (v3.6.1), with Argo Rollouts 2.43.12 (v1.10.2) for step 4's canary.

Three rules about how it is introduced, because they matter more than the install:

**Bootstrap by hand, then self-manage.** Argo CD is installed with `helm upgrade --install` from a values file in this repository, like everything else. Only once it is running and healthy does it get an Application pointing at its own values. A tool that cannot be installed without itself is not a good first step.

**Adopt one component at a time, newest first.** `lab-app` moves under Argo CD first, because it is the only workload whose breakage costs nothing. Then the components with no state, then the ones with volumes. Platform pieces that an outage would make unrecoverable (Calico, MetalLB, Traefik, cert-manager) are adopted last, after the rest has been stable for a week.

**Secrets stay out of Git.** The Secrets created by hand (`grafana-admin`, `prometheus-basicauth`, `lab-pg-app`, the dashboard token) remain created by hand, and Argo CD manages everything else. Sealed Secrets or SOPS is a real decision with its own tradeoffs and it is not part of this step.

Sync policy: automated with `selfHeal` for applications, so a manual edit in the cluster is reverted. `prune` stays off until the repository has been the source of truth for a while, because an accidental deletion in Git should not delete a running workload on the next sync.

## Consequences

The workflow changes, and that is the point: after a component is adopted, `helm upgrade` against it is undone within three minutes by `selfHeal`. Changes go through the repository. This will catch someone out at least once, and that moment is the step working.

Argo CD adds roughly seven pods on urahara. zangetsu keeps running only DaemonSets.

Adoption is not free: a Helm release installed by hand carries ownership metadata, and an Application pointing at the same chart will show `OutOfSync` until the release is adopted or reinstalled through Argo. Doing this one component at a time keeps that confusion to one component at a time.

The repository becomes a dependency of the cluster converging. If GitHub is unreachable, nothing breaks that is already running, but nothing changes either. For a lab that is acceptable; it is worth naming because it is a new failure mode that did not exist in step 2.
