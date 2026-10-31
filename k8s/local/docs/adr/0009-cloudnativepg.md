# 0009. CloudNativePG as the database operator

- Status: accepted
- Date: 2026-10-31

## Context

Step 1 asks to install and operate an existing operator. A database operator shows stateful workloads, failover and backups.

## Options

- **CloudNativePG**: CNCF project, Postgres, multi-arch images, failover and backups built in.
- **Zalando Postgres Operator**: mature, older design built on Patroni.
- **Percona or MongoDB operators**: less common in the target jobs.

## Decision

CloudNativePG.

## Consequences

- Postgres is the database most often seen in job posts.
- With local-path (0006), each instance is pinned to a node. Two instances, one per node, show failover.
- Killing the primary is a planned drill.
