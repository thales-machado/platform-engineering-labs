# PM-0007: placeholders in Git applied to the cluster by Argo CD

- Date: 2026-11-16
- Severity: low (near miss, no user impact)
- Status: closed

## Impact

None reached users. Two ClusterIssuers had their ACME contact address replaced
with the literal string `<ACME_EMAIL>` and kept it for about two hours. The
MetalLB address pool was repeatedly rewritten with `<POOL_START>-<POOL_END>`
and rejected every time by MetalLB's validating webhook.

The near miss is the point: the lab's wildcard certificate expires 2027-02-04,
and a renewal against an ACME account whose contact is not an address is the
kind of failure that surfaces months later, on a weekend, as a dead site.

## What happened

Steps 1 and 2 applied manifests by hand. Three of them carried placeholders,
with the README explaining what to substitute:

```yaml
addresses:
  - <POOL_START>-<POOL_END>
```

That is a reasonable convention for a repository someone reads and copies from,
and it is safe exactly as long as a human is the one applying the file.

Step 4 put Argo CD in charge of those directories with `selfHeal: true`. From
that moment the file stopped being documentation and became desired state,
applied on a timer by a controller that does not read the README.

`metallb` showed `OutOfSync` and the diff made it obvious. `cert-manager-config`
showed `Synced`, because Argo had succeeded: nothing validates an ACME contact
at admission time, so the placeholder was written and accepted. Both issuers
still reported `Ready: True`, since cert-manager caches the account
registration in its Secret and does not re-register on every reconcile.

## Timeline

| Time (-03) | Event |
|---|---|
| ~20:10 | `cert-manager-config` and `metallb` adopted by the app of apps |
| ~20:10 | Argo writes `<ACME_EMAIL>` into both ClusterIssuers; `Synced` |
| 22:08 | `metallb` is `OutOfSync`; the diff shows the pool placeholder |
| 22:10 | `kubectl get clusterissuer` shows the placeholder was applied |
| 22:12 | real values committed for the pool and the Traefik IP |
| 22:14 | ACME address replaced with an alias on our own domain, both issuers `Ready` |

## Root cause

A file can be a template for a reader or desired state for a controller. It
cannot be both. Adoption into GitOps changed which one these files were, and
nothing in the adoption checked for it.

The secondary cause is why it went unnoticed for two hours: `Synced` means the
cluster matches Git. It says nothing about whether Git is correct.

## What was wrong along the way

The adoption order in ADR 0018 was written around blast radius: what breaks if
a sync goes wrong. It did not consider content: whether the files being adopted
describe reality. `cert-manager-config` was put in an early wave because
ClusterIssuers are small and stateless, and that reasoning was sound and
irrelevant.

## Actions

| Action | Where | Status |
|---|---|---|
| Real values in every manifest Argo applies | components/metallb, components/traefik, components/cert-manager | done (2026-11-16) |
| Contact address on a domain we control rather than a personal one, since the repository is public | components/cert-manager/cluster-issuers.yaml | done (2026-11-16) |
| Grep for placeholders before adopting a directory, as part of the adoption checklist | step 4 | done (2026-11-16) |
| CI check that fails on `<PLACEHOLDER>` patterns in anything under a GitOps path | .github/workflows | open |
| Verify the ACME account contact at Let's Encrypt, not only the ClusterIssuer object | cert-manager | open |
