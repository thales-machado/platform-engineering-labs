# 0014. cert-manager with a Let's Encrypt wildcard certificate (DNS-01)

- Status: accepted
- Date: 2026-11-06

## Context

The plan was HTTP only in step 1. In practice the browser upgrades `*.lab.thalespm.me` to HTTPS. Ingresses answered on 443 with Traefik's self-signed default certificate, and the Gateway, which only had an HTTP listener, returned 404 for HTTPS. The lab hostnames resolve only on the LAN (Pi-hole), so Let's Encrypt cannot reach them over HTTP.

## Options

- **Self-signed or a private CA**: no external dependency, but every client must trust the CA.
- **Let's Encrypt, HTTP-01**: needs the hostnames reachable from the internet. Not the case.
- **Let's Encrypt, DNS-01 with Cloudflare**: proves control of the zone through a TXT record; works for private hostnames and allows a wildcard. The homelab already uses this flow.

## Decision

cert-manager, ClusterIssuers for Let's Encrypt staging and production with the Cloudflare DNS-01 solver, and one wildcard certificate (`lab.thalespm.me`, `*.lab.thalespm.me`) in the `traefik` namespace. It is used by the Gateway's HTTPS listener and as Traefik's default certificate for Ingresses.

## Consequences

- One certificate for every lab hostname; cert-manager renews it 30 days before expiry.
- The DNS-01 self-check must use public resolvers (`--dns01-recursive-nameservers-only`, 1.1.1.1 and 8.8.8.8): the LAN's Pi-hole answers everything under `lab.thalespm.me` locally and never returns the TXT record.
- A Cloudflare API token lives in the cluster as a Secret, created by hand and never committed. Scope: DNS Edit and Zone Read on `thalespm.me` only.
- New certificates are tested on staging first; production has rate limits.
