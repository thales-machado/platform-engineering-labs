# PM-0012: kube-proxy replacement stopped pod creation on one node for 31 minutes

- Date: 2026-11-18
- Severity: medium (no user impact, no new pod could start on zangetsu)
- Status: closed, change reverted and ADR 0020 rejected for this hardware

## Impact

From 11:03 to 11:34, no new pod could start on zangetsu. Pods stayed in
`ContainerCreating` with no IP and no events.

Everything already running kept working. Every hostname answered throughout,
the netcheck probes stayed at 1, and the route probes stayed at 1. If a
DaemonSet had needed to restart a pod on that node, or an HPA had scaled a
workload onto it, that would have failed silently.

It was found by a test pod that the runbook asks for, not by an alert.

## What happened

Phase 1 of ADR 0020 set `kubeProxyReplacement: true`. That loads Cilium's
socket load balancer programs, which use CO-RE relocations, which need BTF
information in the running kernel.

```
Failed to initialize datapath, retrying later
error="failed loading eBPF collection into the kernel: program cil_sock4_connect:
apply CO-RE relocations: load kernel spec:
no BTF found for kernel version 6.18.34+rpt-rpi-2712: not supported"
```

zangetsu runs the Raspberry Pi vendor kernel, which ships without BTF. The
agent retried every ten seconds and never initialised its datapath, so the CNI
plugin could not create endpoints:

```
plugin type="cilium-cni" failed (add): unable to create endpoint:
Cilium API client timeout exceeded
```

urahara, on a Debian amd64 kernel with BTF, was unaffected.

This is the second time this kernel has decided a design: PM-0009 exists
because of its missing `ip_tables`, and ADR 0019 had to switch from GENEVE to
VXLAN because it has no `geneve` module.

## Two mistakes of mine in the handling

**I verified one node and called it verified.** The check was
`kubectl -n kube-system exec ds/cilium -- cilium-dbg status`, and `ds/...`
picks one pod. It picked urahara, which reported `KubeProxyReplacement: True`
and healthy controllers. On a cluster with two architectures and two kernels,
every datapath check has to loop over both nodes. The runbook now does.

**The rollback looked like it did nothing.** `helm upgrade` with
`kubeProxyReplacement: false` wrote the new value into the `cilium-config`
ConfigMap, but did not restart the DaemonSet, because the pod spec did not
change. The rollout finished instantly and both agents kept reporting `True`.
Cilium does not reload that setting at runtime, so the revert needs an
explicit `kubectl -n kube-system rollout restart ds/cilium`.

That is worth remembering beyond this incident: for Cilium, a Helm value
change that only touches the ConfigMap is not applied until the agents
restart, and `helm upgrade` reporting success says nothing about it.

## Recovery

```bash
sudo kubeadm init phase addon kube-proxy      # restores the DaemonSet and ConfigMap
# kube-proxy runs with hostNetwork, so it starts even where the CNI is broken
helm upgrade cilium ... -f values.yaml        # kubeProxyReplacement: false
kubectl -n kube-system rollout restart ds/cilium
```

Both nodes then reported `KubeProxyReplacement: False`, controllers healthy,
and a test pod on zangetsu reached the `kubernetes` Service.

## Why the lab did not see it

The probes added yesterday measure traffic between pods that already exist and
routes that already work. Nothing measures whether a new pod can start on each
node.

Same family as PM-0008 and PM-0009: the lab watches the steady state and not
the transitions. A node that cannot create pods looks perfect on every
dashboard until something needs to be scheduled there.

## Action items

- [ ] Alert on pods stuck in a waiting state: `kube_pod_container_status_waiting`
      with `reason="ContainerCreating"` for more than 5 minutes, by node.
- [ ] Before any datapath change, check `/sys/kernel/btf/vmlinux` on every
      node. Its absence rules out every Cilium feature that needs CO-RE.
- [ ] Every datapath verification in a runbook loops over both nodes. Fixed in
      the kube-proxy runbook; check the Cilium migration runbook too.

## Consequence

ADR 0020 is rejected for this hardware. Without kube-proxy replacement there
is no `bpf.masquerade`, so PM-0009 needs a different solution, written up
there.

The underlying constraint is worth stating plainly, because it will come back:
**this cluster cannot use any Cilium feature that requires CO-RE, as long as
zangetsu runs a kernel without BTF.** Socket LB, and therefore kube-proxy
replacement, is one of them.
