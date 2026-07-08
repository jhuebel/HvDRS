# HVDRS — Hyper-V Distributed Resource Scheduler

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/HVDRS.svg)](https://www.powershellgallery.com/packages/HVDRS)

A PowerShell module that brings VMware DRS-style **VM Happiness** load balancing to Windows Server Hyper-V Failover Clusters.

Inspired by the per-VM happiness model introduced in vSphere 7, HVDRS scores every running VM on a **0–100 happiness scale** based on whether it is receiving the CPU and memory resources it demands. Unhappy VMs are automatically live-migrated to better-suited nodes, subject to cluster ownership constraints and a **Network-Aware destination filter** that prevents saturating host NICs.

---

## Features

| Feature | Details |
|---|---|
| **VM Happiness scoring** | Per-VM 0–100 score combining CPU and memory satisfaction |
| **CPU happiness** | Host CPU stress (ramps 70–100%) weighted by the VM's own CPU demand |
| **Memory happiness** | Hyper-V Dynamic Memory pressure counter; host memory utilization for static-RAM VMs |
| **Network-Aware DRS** | Destination hosts above a configurable NIC utilization threshold are excluded |
| **Cluster-aware migration** | Uses `Move-ClusterVirtualMachineRole` and respects possible-owner constraints |
| **Aggression levels 1–5** | Controls happiness threshold and minimum improvement required to trigger a move |
| **Greedy planning pass** | Simulated state is updated after each planned migration so subsequent decisions stay consistent |
| **Affinity / Anti-Affinity rules** | Four compute rule types (VmVmAffinity, VmVmAntiAffinity, VmHostAffinity, VmHostAntiAffinity); hard (enforced) or soft; per-cluster scoping |
| **Storage Affinity / Anti-Affinity rules** | Four storage rule types (VmVmCsvAffinity, VmVmCsvAntiAffinity, VmCsvAffinity, VmCsvAntiAffinity) — keep/separate VMs' storage by CSV, same hard/soft model |
| **VM/Host/CSV Groups** | Reusable named groups (`Add-HvDRSGroup`) referenced from rules via `-VMGroups`/`-HostGroups`/`-CSVGroups`; membership resolves dynamically at rule-load time, no rule re-save needed |
| **Two-pass planner** | Compliance pass fixes hard-rule violations first; happiness pass scores remaining candidates with rule impact adjustments — applies to both compute and storage DRS |
| **Storage DRS** | CSV utilization-based storage rebalancing via `Move-VMStorage`; space + latency happiness scoring; storage affinity rule enforcement |
| **Trend smoothing** | Optional `-TrendWindow` rolling average across consecutive passes so a single transient spike doesn't trigger a migration |
| **Node maintenance evacuation** | `Enter-HvDRSNodeMaintenance` drains a node using the same happiness-aware destination selection, then pauses it — a Hyper-V analog of vSphere's "Enter Maintenance Mode" |
| **Per-VM automation-level override** | `Set-HvDRSVMAutomationLevel -AutomationLevel Manual` pins a VM to recommend-but-never-execute, independent of the global mode |
| **What-if capacity forecasting** | `Get-HvDRSCapacityForecast` simulates draining (`-RemoveNode`) or adding (`-AddNode`) a node and reports the projected happiness impact — read-only, never migrates |
| **Webhook / Event Log notifications** | Optional `-WebhookUrl` JSON POST and/or `-WriteEventLog` Application-log entry summarizing each pass |
| **Dry-run / WhatIf** | Standard PowerShell `-WhatIf` previews recommendations without migrating |
| **Recommend-Only mode** | `-RecommendOnly` switch for monitoring-only scheduled passes |
| **Maintenance mode** | Lock-file mechanism to temporarily freeze both compute and storage migrations |
| **Cluster discovery** | `Get-HvDRSCluster` lists nodes, VMs, and CSVs without collecting performance counters or proposing migrations |
| **VMM PRO Tips (optional)** | Surfaces both compute-DRS and storage-DRS recommendations as VMM PRO Tips for admin approval inside the VMM console; VMM executes the approved migration/move — see [ProPack/PROPACK.md](ProPack/PROPACK.md) |

---

## Why not just use SCVMM's Dynamic Optimization?

If your environment already runs System Center VMM, its **Dynamic Optimization (DO)** feature is the closest built-in equivalent — it live-migrates VMs to balance CPU/memory/disk/network load across a host group on a schedule or on demand. HVDRS overlaps with DO in places (aggressiveness-style tuning, dry-run preview, possible-owner/host-group constraints) but takes a fundamentally different approach to deciding *when* a migration is warranted:

| | SCVMM Dynamic Optimization | HVDRS |
|---|---|---|
| Balances at | **Host level** — minimizes the standard deviation of an aggregate load score across hosts | **VM level** — scores each VM's actual satisfaction against the resources it demands |
| Memory signal | Host memory demand/free % | Hyper-V Dynamic Memory `Current Pressure` counter — distinguishes a comfortably ballooned VM from a genuinely starved one |
| Blind spot | A host can look balanced on average while one VM is starved by NUMA placement, vCPU oversubscription, or a noisy neighbor — DO never sees it, because the host's aggregate score looks fine | Per-VM scoring catches exactly this case |
| Destination selection | Network I/O factors into the host load score, but DO can still migrate a VM *onto* a host about to become a network bottleneck | Network-Aware destination filter explicitly excludes hosts above a NIC utilization threshold as migration targets |
| Affinity | Anti-affinity only, via Availability Sets | Hard/soft affinity *and* anti-affinity, for both compute (VM↔VM, VM↔Host) and storage (VM↔CSV), plus reusable named groups |
| Storage balancing | None — no Storage DRS equivalent; only manual/Quick Storage Migration | Storage DRS pass with CSV space + latency happiness scoring and storage affinity enforcement |
| Per-VM automation control | Automation level is a per-cluster/host-group setting | Per-VM override (`Set-HvDRSVMAutomationLevel`) — pin one workload to manual approval without changing the cluster-wide mode |
| Host maintenance | DO doesn't evacuate a host for you — that's a separate Hyper-V/VMM maintenance-mode workflow | `Enter-HvDRSNodeMaintenance` actively drains a node using the same happiness model, then pauses it |
| Capacity planning | No built-in what-if simulation | `Get-HvDRSCapacityForecast` simulates removing or adding a node before you commit to it |
| Dependencies | Requires a licensed VMM management server (and SCOM for PRO/app-aware triggers) | Runs directly against the Failover Cluster — no management server required |

**Net takeaway:** DO is effective at preventing gross cluster-wide imbalance, but it's a coarser instrument — it optimizes the *cluster's* variance, not any individual VM's experience. HVDRS is most worth using over DO when you care about catching VM-level unhappiness that a healthy-looking host average can hide, when you need real affinity (not just anti-affinity) or CSV-level storage balancing, or when you don't want to stand up/license SCVMM at all.

---

## Optional: VMM PRO Tips Integration

If you *do* run VMM — and have it integrated with Operations Manager (SCOM) — HVDRS can surface its compute-DRS recommendations as **VMM PRO Tips**, so an admin sees and approves them from inside the VMM console instead of from `Invoke-HvDRS` console output or a scheduled task log. VMM executes the approved migration itself; HVDRS only ever runs in `-RecommendOnly` mode for this integration.

This is a **fully optional, separately installed add-on** (`ProPack/`) implemented as a SCOM Management Pack — installing it adds zero dependencies to the core module, and uninstalling it (or never installing it) leaves `Invoke-HvDRS`/`Invoke-HvStorageDRS` completely unaffected.

Prerequisites: SCOM integrated with VMM via the VMM connector, the VMM management pack imported into SCOM, and a Run-As account with cluster-read and VMM-read rights. See [ProPack/PROPACK.md](ProPack/PROPACK.md) for full setup, configuration, and testing details.

---

## Quick Start

```powershell
# Install from PowerShell Gallery: https://www.powershellgallery.com/packages/HVDRS
# (see docs/INSTALL.md for all options)
Install-Module -Name HVDRS -Scope CurrentUser

# Import
Import-Module HVDRS

# Dry run against your cluster
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -WhatIf

# Live run at default aggression (level 3)
Invoke-HvDRS -ClusterName 'PROD-CLUSTER'

# Storage rebalancing pass
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -WhatIf
```

---

## Module Layout

```
HVDRS/
├── HVDRS.psd1                                    # Module manifest
├── HVDRS.psm1                                    # Module loader
└── Functions/
    ├── Private/
    │   ├── Get-ClusterInventory.ps1              # Lightweight node/VM/CSV discovery (no metrics)
    │   ├── Get-ClusterSnapshot.ps1               # Metric collection (CPU, memory, network)
    │   ├── Merge-HvDRSTrendSnapshot.ps1          # Rolling trend-window smoothing (-TrendWindow)
    │   ├── Measure-VmHappiness.ps1               # VM happiness score calculation
    │   ├── Find-MigrationCandidates.ps1          # Two-pass compute migration planner
    │   ├── Find-EvacuationDestination.ps1        # Shared node-evacuation destination selector
    │   ├── Get-AffinityRuleSet.ps1               # Load/save affinity rules from JSON; expands groups
    │   ├── Get-HvDRSGroupSet.ps1                 # Load/save VM/Host/CSV groups from JSON
    │   ├── Get-HvDRSAutomationOverrideSet.ps1    # Load/save per-VM automation-level overrides
    │   ├── Test-AffinityCompliance.ps1           # Current-placement violation detection
    │   ├── Get-MigrationRuleImpact.ps1           # Per-migration rule impact evaluation
    │   ├── Get-StorageSnapshot.ps1               # CSV metric collection (space, IOPS, latency)
    │   ├── Measure-CsvHappiness.ps1              # CSV happiness score calculation
    │   ├── Find-StorageMigrationCandidates.ps1   # Two-pass storage migration planner
    │   ├── Test-StorageAffinityCompliance.ps1    # Current-placement storage violation detection
    │   ├── Get-StorageMigrationRuleImpact.ps1    # Per-migration storage rule impact evaluation
    │   └── Send-HvDRSNotification.ps1            # Webhook POST / event log pass-completion notification
    └── Public/
        ├── Get-HvDRSCluster.ps1                  # Discover nodes, VMs, and CSVs (read-only)
        ├── Invoke-HvDRS.ps1                      # Compute DRS entry point
        ├── Invoke-HvStorageDRS.ps1               # Storage DRS entry point
        ├── AffinityRules.ps1                     # Affinity rule CRUD + compute/storage compliance checks
        ├── Groups.ps1                            # VM/Host/CSV group CRUD
        ├── AutomationOverrides.ps1               # Per-VM automation-level override CRUD
        ├── Get-HvDRSCapacityForecast.ps1          # What-if -RemoveNode / -AddNode simulation
        └── Maintenance.ps1                       # Enable/Disable/Get maintenance mode;
                                                    # Enter/Exit/Get-HvDRSNodeMaintenance* evacuation

ProPack/                                          # Optional VMM PRO Tips add-on — see ProPack/PROPACK.md
├── ManagementPack/HvDRS.ProTips.mp.xml           # SCOM Management Pack (compute + storage pipelines)
├── Scripts/                                      # Probe orchestrators + translation/identity-resolution helpers
└── Tests/                                        # Pester tests for the scripts above
```

---

## Happiness Score Algorithms

### VM Happiness (compute)

```
HappinessScore = (CpuHappiness × CpuWeight) + (MemoryHappiness × MemoryWeight)
                 ─────────────────────────────────────────────────────────────
                                  CpuWeight + MemoryWeight
```

**CPU Happiness** — host CPU stress ramps linearly from 0 at 70% utilization to 1.0 at 100%. A VM that is not demanding CPU remains happy even on a loaded host.

```
stress        = max(0, (hostCpuUtil − 70) / 30)
cpuHappiness  = max(0, 100 − stress × vmCpuUtil)
```

**Memory Happiness — Dynamic Memory** — uses `\Hyper-V Dynamic Memory VM\Current Pressure`. Pressure ≤ 100 means the VM has what it needs; above 150 is fully unhappy.

**Memory Happiness — Static Memory** — proxied from host available memory utilization (fully happy ≤ 70%, fully unhappy ≥ 90%).

### CSV Happiness (storage)

**Space happiness** — based on free space percentage:

| Free % | Score |
|---|---|
| ≥ 40% | 100 |
| 20–40% | 50 + (pct – 20) × 2.5 |
| 10–20% | (pct – 10) × 5 |
| < 10% | 0 |

**IO happiness** — based on average disk transfer latency. Falls back to space-only automatically when counters are unavailable.

| Latency | Score |
|---|---|
| ≤ 5 ms | 100 |
| 5–20 ms | 100 − (lat – 5) × 6.67 |
| > 20 ms | 0 |

---

## Aggression Levels

Same thresholds apply to both compute and storage DRS:

| Level | Trigger below | Minimum improvement | Typical use |
|-------|--------------|---------------------|-------------|
| 1 | 30 | 40 pts | Conservative — only severe imbalance |
| 2 | 40 | 30 pts | Cautious |
| 3 | 50 | 20 pts | **Default** — balanced |
| 4 | 60 | 15 pts | Proactive |
| 5 | 70 | 10 pts | Aggressive — prefer balance over stability |

---

## Public Functions

| Function | Purpose |
|---|---|
| `Get-HvDRSCluster` | Discover nodes, VMs, and CSVs on a cluster — read-only, no performance counters collected |
| `Invoke-HvDRS` | Run a compute DRS balancing pass |
| `Invoke-HvStorageDRS` | Run a storage DRS balancing pass |
| `Add-HvDRSAffinityRule` | Define a new affinity or anti-affinity rule |
| `Get-HvDRSAffinityRule` | List rules with optional filtering |
| `Remove-HvDRSAffinityRule` | Delete a rule by name or ID |
| `Set-HvDRSAffinityRule` | Modify an existing rule |
| `Test-HvDRSAffinityCompliance` | Check current cluster placement against all compute rules |
| `Test-HvDRSStorageAffinityCompliance` | Check current VM-to-CSV storage placement against all storage rules |
| `Add-HvDRSGroup` / `Get-HvDRSGroup` / `Remove-HvDRSGroup` / `Set-HvDRSGroup` | Manage reusable VM/Host/CSV groups referenced from rules via `-VMGroups`/`-HostGroups`/`-CSVGroups` |
| `Set-HvDRSVMAutomationLevel` / `Get-HvDRSVMAutomationLevel` / `Remove-HvDRSVMAutomationLevel` | Pin a VM to Manual automation (recommend-but-never-execute) or revert to FullyAutomated |
| `Get-HvDRSCapacityForecast` | Read-only what-if: simulate draining (`-RemoveNode`) or adding (`-AddNode`) a node |
| `Enable-HvDRSMaintenance` | Create maintenance lock file (freeze migrations) |
| `Disable-HvDRSMaintenance` | Remove lock file (resume migrations) |
| `Get-HvDRSMaintenanceStatus` | Check whether maintenance mode is active |
| `Enter-HvDRSNodeMaintenance` | Evacuate a node using happiness-aware placement, then pause it |
| `Exit-HvDRSNodeMaintenance` | Resume a paused node |
| `Get-HvDRSNodeMaintenanceStatus` | Check paused/up state for one or all nodes |

---

## Requirements

- Windows Server 2016 or later
- Hyper-V role installed on all cluster nodes
- Windows Failover Clustering feature
- PowerShell 5.1 or later
- The account running the script must have **cluster administrative rights** and permission to perform Live Migrations

See [docs/INSTALL.md](docs/INSTALL.md) for full prerequisites and deployment instructions.  
See [docs/USAGE.md](docs/USAGE.md) for detailed examples, scheduling, and tuning guidance.  
See [docs/TESTS.md](docs/TESTS.md) for the test suite layout, coverage details, and how to run the tests.  
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module's internal design.

---

## License

MIT License — see [LICENSE](LICENSE).
