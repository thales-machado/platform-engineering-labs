# PM-0011: half of every lookup for the lab's own hostnames returned NXDOMAIN

- Date: 2026-11-17 (latent since the cluster was built)
- Severity: medium (no outage; any in-cluster use of a lab hostname was a coin flip)
- Status: fixed

## Impact

From inside the cluster, every `*.lab.thalespm.me` name resolved about half the
time. Measured over fifteen minutes: `prometheus` 0.13, `grafana` 0.53,
`argocd` 0.67, `app` 0.67, `dashboard` 0.73, `rollouts` 0.80. A failed lookup
produced `probe_success 0` with `probe_http_status_code 0`, a connection that
never opened.

Nothing broke, because nothing inside the cluster used those names until the
probes added for PM-0008 did, on 2026-11-17. The defect had been there since
the cluster was built.

## Cause

Both nodes list two resolvers:

```
nameserver 192.168.15.248   Pi-hole VIP
nameserver 1.1.1.1
```

CoreDNS forwards with `forward . /etc/resolv.conf`, and its `forward` plugin
spreads queries across every upstream it is given. The lab's hostnames exist
only in Pi-hole, as a split horizon with no public A record, so the queries
that landed on 1.1.1.1 came back NXDOMAIN.

The reason this is easy to miss is the difference between two resolvers that
read the same file:

- The C library on the node tries the first `nameserver` and only falls
  through to the second when the first fails or times out. Pi-hole answers, so
  the second entry is never used. `curl` from a node always worked.
- CoreDNS's `forward` treats the list as a pool to balance across. Roughly half
  the traffic goes to the second entry by design.

Same file, same two addresses, opposite behaviour. That is the whole bug.

## Why it stayed hidden

The cluster had no reason to resolve its own public names:

- Workloads talk to each other through `*.svc.cluster.local`.
- The SLO probe runs from the homelab, outside the cluster, through the LAN
  resolver.
- cert-manager asks public resolvers explicitly, with
  `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53`, because the DNS-01
  self-check must not ask Pi-hole. That flag made cert-manager immune to this
  and removed the one workload that might have found it.

So the lab had a broken path that nothing walked. The probes did not create the
problem; they were the first thing to use the path.

## Fix

A stub zone in the Corefile, sending that domain to Pi-hole alone:

```
thalespm.me:53 {
    errors
    cache 30
    forward . 192.168.15.248
}
```

Pi-hole resolves the public names of that domain upstream, so nothing outside
the split horizon changes. After the fix: six probes out of six at 1 over ten
minutes, and six lookups out of six returning `192.168.15.241` from a test pod.

The ConfigMap is now in Git under `components/coredns/` with its own Argo
Application. kubeadm owns that ConfigMap and rewrites it during an upgrade,
keeping a backup as `coredns-backup-v<version>`; Argo restores the stub zone
within three minutes, which is the behaviour we want and a disagreement to
expect during step 1 work.

## What to take from it

Two things worth more than the fix.

A resolver list is not a priority list everywhere. Anything that reads
`/etc/resolv.conf` on a node and then forwards may balance rather than fall
back, and split-horizon DNS turns that into a coin flip instead of an error.

And a path nobody walks is not a path that works. This was found on the first
afternoon something inside the cluster had a reason to resolve a lab hostname,
which is also when it was first measured. Both postmortems of 2026-11-17 are
the same lesson from different directions.
