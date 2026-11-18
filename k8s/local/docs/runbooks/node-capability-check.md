# Runbook: node capability check

Run this on **every node** before any change to the datapath, the CNI, the
kernel-facing parts of an agent, or anything that loads eBPF.

It exists because the same mistake has now been made four times in this lab,
always the same way: a design decided for "the cluster" when the nodes do not
have the same capabilities.

| What the kernel lacked | What it cost |
| --- | --- |
| `geneve` module | ADR 0019 phase 2 failed, node drained, retry |
| legacy `ip_tables` | PM-0009, ten hours with no pod egress on one node |
| BTF | PM-0012, 31 minutes with no pod creation on one node |

Three of those were already written down somewhere in these repositories
before they were hit. The check below is one minute of work.

## The check

```bash
for ip in 192.168.15.215 192.168.15.214; do
  echo "=========== $ip"
  ssh keydrop@$ip 'bash -s' <<'EOS'
echo "kernel:   $(uname -r)  $(uname -m)"
echo -n "BTF:      "; [ -f /sys/kernel/btf/vmlinux ] && echo present || echo MISSING
echo -n "cgroup:   "; stat -fc %T /sys/fs/cgroup
echo "modules:"
for m in vxlan geneve ip_tables nf_tables veth; do
  if lsmod | grep -q "^$m " ; then echo "  $m: loaded"
  elif modprobe -n -q $m 2>/dev/null; then echo "  $m: available"
  else echo "  $m: MISSING"; fi
done
echo "netfilter tables readable by iptables:"
for t in raw mangle nat filter; do
  printf "  %-7s " $t
  sudo iptables -t $t -S >/dev/null 2>&1 && echo ok || echo INCOMPATIBLE
done
echo "nft tables:"; sudo nft list tables | sed 's/^/  /'
EOS
done
```

## How to read it

**BTF missing** rules out every Cilium feature that needs CO-RE relocations.
That includes the socket load balancer, so it rules out kube-proxy
replacement, and therefore `bpf.masquerade` and eBPF host routing. PM-0012.

**A module missing** rules out whatever needs it. `geneve` is the example that
cost a retry in ADR 0019; the encapsulation protocol has to be one that both
kernels actually have.

**A table reported INCOMPATIBLE** means something wrote native nft rules into
it and `iptables-nft` will not touch it. Anything on that node that manages
netfilter through iptables will fail silently, including Cilium's masquerade.
PM-0009.

**Different kernels on different nodes** is the thing to notice first. One
node on a distribution kernel and one on a vendor kernel is not one cluster
for this purpose, it is two, and a feature has to work on both.

## When to run it

- Before writing an ADR that touches the datapath. The answers belong in the
  ADR's context section, not in a surprise during the runbook.
- Before the first command of any CNI, kube-proxy or eBPF change.
- After a kernel upgrade on any node, because a vendor kernel can lose a
  feature as easily as gain one.

## What to do when a node fails the check

Write it in the ADR and pick a design both nodes support, or decide to change
the node. Do not design for the better node and hope. That is what produced
every row in the table above.
