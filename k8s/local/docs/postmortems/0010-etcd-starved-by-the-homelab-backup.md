# PM-0010: the nightly backup starved etcd and broke the control plane for 15 hours

- Date: 2026-11-17
- Severity: high (control plane unavailable in bursts, cluster unmanageable)
- Status: fixed (throttle applied and verified on the next run)

## Impact

From 03:46 to at least 18:40, the API server on urahara failed its readiness
probe 228 times and its liveness probe 59 times. The kubelet killed and
recreated it repeatedly, reaching attempt 13. It took the rest of the control
plane with it: `kube-scheduler` and `kube-controller-manager` reached attempt
12, `kube-state-metrics` 17, `argo-rollouts` 16.

During each burst `kubectl` returned `connection refused`, the HPA could not
read metrics, Argo flipped applications between Healthy and Degraded, and
container creation failed with name collisions in containerd.

Nothing alerted. It was found at 18:33, fifteen hours after it started,
because a `kubectl` command failed while investigating something unrelated.

## The chain

```
02:45  Restic backup starts, reads /opt and /etc on urahara
03:46  API server readiness probe starts failing with 500
03:50  etcd WAL fsync p99 >= 8.2s   disk read 292 MB/s
03:52  node disk write latency 1718ms
04:35  etcd WAL fsync p99 >= 8.2s   disk read 393 MB/s   (backup retry)
09:05  etcd WAL fsync p99 >= 8.2s   disk read 468 MB/s
14:20  etcd WAL fsync p99 >= 8.2s   disk read 510 MB/s
18:30  etcd WAL fsync p99 >= 8.2s   disk read 387 MB/s
18:32  API server attempt 13, containerd name collisions across six pods
```

Every fsync peak sits on a read burst. etcd targets 10ms for that metric.

## Root cause

The homelab's `restic-backup-urahara` DAG runs at 02:45 and reads `/opt` and
`/etc`. `/opt/local-path-provisioner` is there, so the backup walks the lab's
Prometheus TSDB, Loki's chunks and `lab-pg-1`'s data directory, with no I/O
limit. It writes to `/mnt/backup/urahara`, a CIFS mount to the NAS, so the job
is bounded by the network while reading the NVMe flat out. A job that would
take six minutes at local speed spends an hour reading at 400 MB/s.

`/var/lib/etcd` is on that same NVMe. etcd cannot tolerate this: its writes are
small and synchronous, and it has no isolation from a reader saturating the
queue. Disk utilisation only reached 0.73, which is why this does not look like
saturation in a dashboard: the device was not busy, individual operations were
simply queued behind a flood of large reads.

The disk is healthy. SMART reports zero media errors, 3% life used, 50C. Idle
write latency is 0.29ms. This is contention, not hardware, and PM-0006's open
suspicion about this machine's RAM is not what caused today.

## Why the day never recovered

Hypothesis, not proven: once the API server starts failing, the kubelet
recreates containers, every `CreateContainer` reads image layers off the same
NVMe, and that read burst stalls etcd again. The 09:05, 14:20 and 18:30 peaks
have no scheduled job behind them, and each one coincides with a restart
storm. The failure feeds itself.

What is certain is that the first peak is the backup, and that nothing broke
the loop because nothing was watching.

## Why nothing alerted

The lab has twelve alerts. `k8s-lab-control-plane-restart` fires on restarts of
exactly these pods, with a 15-minute window, and it was written after PM-0006
for this class of failure.

It did not reach the phone, and I have not established whether it fired and the
notification failed, or whether it never fired because the metric it reads
comes from `kube-state-metrics`, which was itself being killed, through a
Prometheus whose scrapes were failing, on the disk that was stalling. That is
the thing to check next, and it is a general lesson: an alert that depends on
the failing component is not an alert.

None of the twelve watch `etcd_disk_wal_fsync_duration_seconds`, which went
past 8 seconds four hours before the first visible symptom.

## Actions

- [ ] Alert on `etcd_disk_wal_fsync_duration_seconds` p99 > 100ms for 5m,
      critical. Prepared as `k8s-lab-etcd-slow-fsync`.
- [ ] Cap the backup's read bandwidth: `--device-read-bps /dev/nvme0n1:100mb`
      on the DAG's `docker run`.
- [ ] Establish why `k8s-lab-control-plane-restart` did not notify. Check
      Grafana's alert state history for today.
- [ ] Consider whether the lab's Prometheus and Loki belong on the same device
      as etcd at all. Moving them to the SATA disk costs query speed and buys
      isolation for the control plane.

## Verification, 2026-11-18

The read cap was applied on 2026-11-17 at 19:08, before that night's backup.
The next run of the same job, on the same host and disk:

| | 2026-11-17 | 2026-11-18 |
| --- | --- | --- |
| etcd WAL fsync p99, backup window | >= 8192 ms | 41 ms |
| control plane restarts | 13 | 0 |

One line of configuration, two orders of magnitude. The backup takes longer and
no longer competes with etcd for the queue.

That also settles the open question from the hypothesis above: the daytime
read bursts were the failure feeding itself. With the first trigger removed,
there were none.

## What this says about the lab

The cluster was never the problem. Every component behaved correctly: etcd
reported slow fsync, the API server failed its probes honestly, the kubelet
restarted what looked dead, Argo kept reconciling. The failure came from
outside Kubernetes entirely, from a backup job in a different repository, on a
host that is both a Kubernetes node and a Docker homelab.

That is the real lesson of running a lab on shared hardware, and it is worth
more than a clean migration: the blast radius of a change is not bounded by the
system you are changing.
