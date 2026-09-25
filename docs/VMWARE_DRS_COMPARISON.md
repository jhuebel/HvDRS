# HVDRS vs. VMware vSphere DRS — Feature Comparison

HVDRS's per-VM Happiness model is explicitly inspired by the scoring approach VMware introduced in vSphere 7 DRS (see the [README](../README.md)). This document is the honest accounting of the gap: what full VMware DRS — plus its usual companions, vSphere HA and Storage DRS — does that this module does not, and why.

The short version: HVDRS reimplements DRS's *core load-balancing loop* — score each workload, propose a move, respect placement constraints — against Hyper-V/Failover Clustering, which has no equivalent built-in. It does not reimplement the platform DRS is embedded in: a central management plane (vCenter) with a resource-allocation hierarchy, an admission-control/HA subsystem, and over a decade of adjacent features layered on top of the scheduler itself.

---

## Feature-by-feature

| Feature | VMware DRS (+ vSphere HA / Storage DRS) | HVDRS | Gap |
|---|---|---|---|
| Per-workload scoring | VM DRS Score (0–100), vSphere 7+, computed from CPU/memory/network execution efficiency | VM Happiness score (0–100), CPU + memory | **Close parity** — HVDRS has no network term in the score itself (network is a destination *gate*, not a scoring input) |
| Migration threshold | 5-level slider (conservative → aggressive) | `-AggressionLevel` 1–5 | **Parity** |
| Hard/soft VM-VM and VM-Host affinity & anti-affinity | Yes — DRS rules and VM/Host groups | Yes — `Add-HvDRSAffinityRule`, VM/Host/CSV groups | **Parity** |
| Per-VM automation override | Yes — per-VM automation level overrides the cluster default | Yes — `Set-HvDRSVMAutomationLevel` | **Parity** |
| Storage-level balancing | Storage DRS: datastore clusters, space + I/O (Storage I/O Control) balancing, VMDK anti-affinity within a VM, automated Storage vMotion | `Invoke-HvStorageDRS`: CSV space + latency happiness, storage affinity rules, automated `Move-VMStorage` | **Partial** — no per-VMDK anti-affinity inside one VM, no SIOC-derived contention signal (latency is sampled directly, best-effort), no datastore-cluster admission control |
| Initial placement | DRS chooses the host (and, with Storage DRS, the datastore) when a VM is powered on or created | None — HVDRS only rebalances VMs that are already running | **Missing.** A newly created/started VM lands wherever Hyper-V/Failover Clustering puts it; HVDRS won't reconsider it until the next scheduled pass |
| Resource Pools & Shares | Hierarchical CPU/memory entitlement (shares, reservations, limits) across pools of VMs; **Scalable Shares** auto-adjust entitlement as pool membership changes | None — no concept of reservations, limits, or relative priority. Every VM is scored purely on current demand vs. current host stress | **Missing.** HVDRS cannot express "this VM matters more than that one" beyond the binary Manual/FullyAutomated pin |
| Distributed Power Management (DPM) | Consolidates VMs onto fewer hosts during low utilization and powers the freed hosts off (IPMI/iLO/WoL), powering them back on as demand returns | None | **Missing entirely.** `Enter-HvDRSNodeMaintenance` drains and pauses a node, but only on explicit request — nothing evaluates cluster-wide utilization and decides a node is worth powering off, and nothing powers it back on |
| Predictive DRS | Uses forecasted metrics from vRealize/Aria Operations to pre-emptively balance ahead of an expected spike | None — `-TrendWindow` only smooths a rolling average of *past* samples; it has no forecasting model | **Missing.** HVDRS is reactive-with-smoothing, not predictive |
| Network-aware placement | Since vSphere 7, network load is a first-class input to the DRS cost model, alongside CPU/memory, including reserved bandwidth (NIOC) | Network-Aware *destination filter* only: a candidate host is excluded outright above `-MaxDestinationNetworkUtil`; network is never weighed against CPU/memory in the score, and bandwidth reservations don't exist on Hyper-V/Failover Clustering the way NIOC does on vSphere | **Partial** — a coarser, gate-only version of the idea |
| Assignable Hardware / device-aware placement | DRS-aware placement for VMs with vGPU, DirectPath I/O, or other assignable devices — only considers hosts with a compatible, available device | None | **Missing** |
| vSphere HA integration | DRS and HA cooperate: HA restarts VMs from a failed host using DRS-informed placement, and admission control reserves capacity for that scenario | None. Windows Failover Clustering will restart VMs from a failed node using its own default placement, but HVDRS's happiness-aware selection logic is never consulted during an unplanned failover — only for planned evacuations you initiate yourself | **Missing.** No admission control, no HA-aware placement |
| Maintenance-mode evacuation | Entering Maintenance Mode in vCenter automatically evacuates every VM (and, per-datastore, Storage DRS can do the same for storage) | `Enter-HvDRSNodeMaintenance` does the compute-side equivalent — same happiness-aware destination selection, refuses to pause if any VM can't be placed, holds the HVDRS maintenance lock for the duration | **Close parity**, compute-side. No equivalent "storage maintenance mode" that proactively empties a CSV |
| Faults / recommendation history UI | vCenter shows why a recommendation was or wasn't applied, with a searchable fault history | Console/`-Verbose` output, `-PassThru` structured objects, optional webhook/event-log summary per pass | **Different shape**, not missing — there's no persistent, browsable history unless you build one from the webhook/event-log data yourself |
| Central management plane | vCenter Server: one place to configure and observe DRS across every cluster it manages | None — each `Invoke-HvDRS`/`Invoke-HvStorageDRS` call is scoped to one cluster, driven by whatever calls it (a scheduled task, typically) | **Missing**, by design — see [ARCHITECTURE.md](ARCHITECTURE.md). HVDRS is a script-driven tool, not a managed service |
| Cross-vCenter / hybrid workload balancing | vMotion (and DRS-informed placement) can move VMs across clusters under one vCenter, or across vCenters/regions in more advanced configurations | Single Failover Cluster only | **Missing** |

---

## Why the gap exists, not just what it is

Most of what's missing above isn't an oversight — it's infrastructure VMware DRS gets for free by living inside vCenter, which Hyper-V/Failover Clustering has no equivalent of:

- **Resource Pools, Shares, and admission control** require a persistent allocation model vCenter maintains across the whole inventory. Building that from scratch (rather than reusing VMware's) is a different, much larger project than a DRS-style scheduler.
- **DPM** needs authenticated out-of-band power control (IPMI/iLO/RAC) integrated with the scheduler's own placement decisions — deliberately out of scope; see the [README](../README.md#requirements) for what HVDRS assumes it can touch (the cluster and Hyper-V hosts, nothing at the BMC/hardware layer).
- **Predictive DRS** depends on Aria/vROps' forecasting engine. There's no Microsoft-native equivalent HVDRS could plug into; building real forecasting (not just a rolling average) was judged out of scope for this project.
- **HA-integrated placement and admission control** would mean HVDRS inserting itself into Failover Clustering's own failover path, which is a materially riskier integration point than the planned-migration and planned-evacuation paths HVDRS uses today (`Move-ClusterVirtualMachineRole`, `Suspend-ClusterNode`).

## Where the comparison is closer than it might look

- **Per-VM scoring, aggression levels, hard/soft affinity, per-VM automation overrides, and maintenance-mode evacuation** are at or near parity in *concept*, even though the implementations are independent (HVDRS predates none of this — it's explicitly modeled on vSphere 7's approach, not a clean-room design).
- HVDRS's storage story (`Invoke-HvStorageDRS`) is a real, if simpler, analog of Storage DRS — CSV-level space/latency scoring, storage affinity rules, and automated `Move-VMStorage` — rather than nothing.
- Both tools' actual placement mechanics — VMware's vMotion/Storage vMotion, HVDRS's `Move-ClusterVirtualMachineRole`/`Move-VMStorage` — are live migrations with no VM downtime.

## What this means in practice

If your environment needs Resource Pools with share-based entitlement, Distributed Power Management, Predictive DRS, HA-integrated failover placement, or vGPU/Assignable-Hardware-aware scheduling, HVDRS does not provide those — full VMware DRS+HA, or (compute-side only) System Center VMM's Dynamic Optimization plus PRO, are the tools with that scope today. See [the SCVMM comparison in the README](../README.md#why-not-just-use-scvmms-dynamic-optimization) for how HVDRS stacks up against the closer-scoped, Hyper-V-native alternative.

If what you need is VM-level happiness-aware compute and storage load balancing, with real affinity enforcement and per-VM automation control, directly against a Failover Cluster and without standing up a management server — that's the actual scope of this project, and the table above should make clear where it does and doesn't reach.
