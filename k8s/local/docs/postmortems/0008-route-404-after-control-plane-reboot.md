# PM-0008: a route served 404 for five minutes after the control plane reboot

- Date: 2026-11-17
- Severity: low (near miss, lab only)
- Status: open (action items pending)

## Impact

`prometheus.lab.thalespm.me` answered Traefik's own `404 page not found` for
about five minutes after urahara rebooted, while `app.lab.thalespm.me` on the
same Gateway answered 200 the whole time. It recovered without intervention.

No user impact, but nothing reported it either. The five minutes were found by
accident, because a query against that hostname failed to parse and the error
looked like a wrong password.

## What happened

The reboot was phase 3 of the Calico to Cilium migration (ADR 0019), so it was
planned and the node was drained first. Traefik had been evicted to zangetsu
by that drain and kept running there.

urahara carries the only API server. When it went down, every Traefik watch
ended in the same second:

```
02:57:16  "Warning: watch ended with error" type="*v1.HTTPRoute"
          err="unable to decode an event from the watch stream:
               http2: client connection lost"
```

The same line repeats for `Middleware`, `Secret`, `Service`, `EndpointSlice`,
`Namespace`, `ConfigMap` and a dozen more.

Timeline, local time:

| Time | Event |
| --- | --- |
| 23:57 | urahara reboots, API server gone, all Traefik watches die |
| 00:02 | `app` answers 200, so the Gateway is serving again |
| 00:03 | `prometheus` answers Traefik's 404 |
| 00:06 | `prometheus` answers 401, with no change made to anything |

Throughout, the HTTPRoute reported `Accepted: True` and `ResolvedRefs: True`,
and both the `prometheus-auth` Middleware and the `prometheus-basicauth` Secret
existed and were unchanged. The control plane's view of the route was correct
and complete while the proxy was not serving it.

## Why the status was useless here

`Accepted` means the controller accepted the route's declaration. It does not
mean a router exists in the running proxy. Those are two different facts and
only the first one is in the API.

This is the same shape as PM-0005, where MetalLB reported a healthy speaker on
a node that was excluded from load balancing: an object that says it is fine
about a thing it does not actually measure.

## Why that route and not the others

Unverified. The routes that came back first have a plain `backendRefs` rule.
The one that came back late is the only one with an `ExtensionRef` filter, so
building its router needs the Middleware informer and that Middleware's Secret,
two more caches that have to resync first.

Plausible, and not proven. Writing it down as a hypothesis so the next control
plane reboot can test it instead of guessing again.

## Correction, 2026-11-17

PM-0011 was found later the same day: half of every lookup for a lab hostname
from inside the cluster returned NXDOMAIN, and had done so since the cluster
was built.

That does not explain the 404. A failed lookup never reaches Traefik, and
Traefik is what answered `404 page not found`. But this postmortem's timeline
rests on probes and curls issued from inside and outside the cluster in the
same window, and the in-cluster half of that evidence was unreliable. The
claim that the route took five minutes to come back is the part to treat as
approximate.

## Action items

- [ ] Probe every real hostname, not only the two netcheck targets. The
      blackbox exporter already runs in-cluster; the Probe objects only cover
      pod-to-pod paths, so no hostname of the lab is watched from inside.
- [ ] Alert on a 404 from a hostname that has an HTTPRoute. A 404 with a route
      declared means the proxy is not serving what the API says it should, and
      it is distinguishable from a 503, which means the backend is down.
- [ ] Next control plane reboot: record the time each hostname starts
      answering, and check whether the filtered route is reliably the last one.

## What went right

The reboot itself did what ADR 0019 said it would: the database was promoted
first, the drain moved everything that could move, and the node came back with
Cilium owning the dataplane. The gap was in what the lab watches, not in the
change.
