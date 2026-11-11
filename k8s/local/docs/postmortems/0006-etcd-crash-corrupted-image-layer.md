# PM-0006. etcd crash loop from a corrupted image layer on disk

- ID: PM-0006
- Date: 2026-11-09 (detected 2026-11-11)
- Status: closed
- Severity: high

## Impact

The control plane of the lab cluster was down for about 41 hours, from 2026-11-09 21:47 to 2026-11-11 14:46. `kubectl` returned `connection refused` the whole time.

No data was lost and no user traffic was affected. The app, the Ingress, DNS and PostgreSQL kept serving, because containerd keeps running the pods it already has and the kube-proxy and Calico rules were already in the kernel. What stopped was every change: no rescheduling, no scaling, no certificate renewal, no new pods.

The outage was found by accident, two days later, while starting step 2. Nothing alerted.

## Timeline

| Time (-03) | Event |
|---|---|
| 11-09 17:04 | `kubeadm upgrade apply v1.37.2` writes the etcd manifest with image `registry.k8s.io/etcd:3.7.0-0`. etcd starts and the cluster is healthy. |
| 11-09 17:10 | kubelet restarted for the 1.37.2 package upgrade; etcd restarts and runs. |
| 11-09 20:15 | Last healthy check of step 1.23: both nodes `Ready`, PostgreSQL healthy, app answering. |
| 11-09 21:47:52 | The etcd container exits with status 2. Every retry since then dies in about 70 ms with `SIGSEGV` in `runtime.chansend` during Prometheus collector registration. |
| 11-09 21:49 | The API server stops answering. The kubelet backoff reaches its 5-minute maximum and stays there. |
| 11-11 13:42 | Found: `kubectl` fails with `connection refused`. |
| 11-11 14:31 | etcd 3.7.0 starts normally from the `native` snapshotter and crashes from `overlayfs`, with the same image, host and flags. |
| 11-11 14:39 | The binary extracted from the image layer has a different sha256 from the one on disk. The good copy is written over it. |
| 11-11 14:40 | etcd `Running`. |
| 11-11 14:46 | kube-apiserver `Running` (restart count 474), both nodes `Ready`, no pod outside `Running`, PostgreSQL healthy with zero replication lag. |

## Root cause

The unpacked image layer on disk held a corrupted etcd binary.

```
image layer   6f27ae12fec11d33dafbce9ca8dff02bd15447355dac90b311270896e72513fa
on disk       eca7b4352aea2cd020153edae1c4b1bc9c36c96bbb1bbc851f639e8e3c968845
```

Both files are 24,776,866 bytes. The file was not truncated: bytes changed inside it. A damaged instruction stream crashes wherever execution reaches the damage, which is why the stack pointed at the Go runtime and at `client_golang` instead of at anything etcd does.

The containerd content store was also missing one amd64 layer blob of the same image (`images check` reported `incomplete (16/18)`), which broke a fresh `native` unpack until the blob was fetched again. The same event probably damaged both.

Two details explain the shape of the incident:

- **Why it ran for four and a half hours.** The process that started at 17:04 was already mapped in page cache. The damage only mattered when the container was recreated at 21:47 and the file was read from disk again.
- **Why nothing detected it.** containerd verifies the digest of the compressed blob when it fetches it. The file the kubelet executes is the extracted copy in the snapshotter, and nothing verifies that one, ever.

What triggered the container restart at 21:47, and what corrupted the file, are not known. No machine-check, EDAC, OOM or I/O error appears in the kernel log.

## What fixed it

```bash
# extract the layers of the amd64 manifest to a temporary directory
sudo ctr -n k8s.io content fetch --platform linux/amd64 registry.k8s.io/etcd:3.7.0-0
# compare and replace
sudo sha256sum /tmp/etcdlayer/usr/local/bin/etcd <snapshot>/fs/usr/local/bin/etcd
sudo cp /tmp/etcdlayer/usr/local/bin/etcd <snapshot>/fs/usr/local/bin/etcd
# force the kubelet to rebuild the pod, clearing the backoff
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/; sleep 10; sudo mv /root/etcd.yaml /etc/kubernetes/manifests/
```

Writing into a committed snapshot is not supported by containerd and is a repair, not a procedure. The supported route is deleting the image so the garbage collector drops the snapshot and the next pull extracts it again. `crictl rmi` on the tag and on the digest did not release the snapshot here, so the file was replaced by hand.

## What was wrong along the way

Three hypotheses were tested and killed before the right one, which is worth recording because each cost time:

- **Corrupted database.** `etcdutl snapshot status` showed the file intact: revision 771207, 787 keys, 37 MB.
- **A Go runtime bug around `GOMAXPROCS`.** The dump showed the new dynamic `GOMAXPROCS` goroutine. `GOMAXPROCS=1` and `GODEBUG=updatemaxprocs=0,containermaxprocs=0` both crashed the same way.
- **Transparent huge pages.** The host had `transparent_hugepage=always` and `overcommit_memory=1`, both non-default and both set by something in the homelab. `GODEBUG=disablethp=1` and switching the host to `madvise` changed nothing.

One wrong step also cost a round: removing the image and pulling it again looked like a clean retest, but containerd kept the unpacked layer, so the test proved nothing. The clean-room run with a different snapshotter is what settled it.

## Actions

| Action | Where | Status |
|---|---|---|
| External blackbox probe on the API server's `/readyz` and on the app, alerting in 2 minutes, from the homelab stack and not from inside the cluster | step 2.1, [monitoring/external/](../../monitoring/external/) | written, not applied |
| Alert when etcd is not ready, and on restarts of control plane static pods | step 2.3 | open |
| Weekly integrity check of unpacked image layers against their image content | step 2.4 | open |
| memtest on urahara: SMART is clean (0 media errors, 3% used), so unbuffered RAM is the remaining suspect | host | open |
| Check SMART and media errors on urahara's NVMe | host | done (2026-11-11): clean, 0 media errors, 0 log entries, 3% used, 51 C |
| Verify the other unpacked layers on both nodes against their image layers | step 2 | open |
| Install `crictl` on both nodes: with the API server down it is the only way to see containers | host | done (urahara, 2026-11-11) |
| Keep taking an etcd snapshot before every upgrade | step 1.23 | done |
| Host sysctls set by homelab containers (`transparent_hugepage`, `overcommit_memory`) should be explicit and versioned, not a side effect | homelab | open |
