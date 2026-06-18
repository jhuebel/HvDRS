# HVDRS — Hyper-V Distributed Resource Scheduler

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
| **Dry-run / WhatIf** | Standard PowerShell `-WhatIf` previews recommendations without migrating |
| **Recommend-Only mode** | `-RecommendOnly` switch for monitoring-only scheduled passes |
| **Maintenance mode** | Lock-file mechanism to temporarily freeze migrations during maintenance windows |

---

## Quick Start

```powershell
# Install the module (see INSTALL.md for full options)
Copy-Item -Recurse .\HVDRS "C:\Program Files\WindowsPowerShell\Modules\"

# Import
Import-Module HVDRS

# Dry run against your cluster
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -WhatIf

# Live run at default aggression (level 3)
Invoke-HvDRS -ClusterName 'PROD-CLUSTER'
```

---

## Module Layout

```
HVDRS/
├── HVDRS.psd1                          # Module manifest
├── HVDRS.psm1                          # Module loader
└── Functions/
    ├── Private/
    │   ├── Get-ClusterSnapshot.ps1     # Metric collection (CPU, memory, network)
    │   ├── Measure-VmHappiness.ps1     # Happiness score calculation
    │   └── Find-MigrationCandidates.ps1# Migration planning
    └── Public/
        ├── Invoke-HvDRS.ps1            # Main entry point
        └── Maintenance.ps1             # Enable/Disable/Get maintenance mode
```

---

## Happiness Score Algorithm

```
HappinessScore = (CpuHappiness × CpuWeight) + (MemoryHappiness × MemoryWeight)
                 ─────────────────────────────────────────────────────────────
                                  CpuWeight + MemoryWeight
```

**CPU Happiness**
Host CPU stress ramps linearly from 0 at 70% utilization to 1.0 at 100%.
A VM that is not demanding CPU remains happy even on a loaded host.

```
stress        = max(0, (hostCpuUtil − 70) / 30)
cpuHappiness  = max(0, 100 − stress × vmCpuUtil)
```

**Memory Happiness — Dynamic Memory**
Uses the `\Hyper-V Dynamic Memory VM\Current Pressure` performance counter.
Pressure ≤ 100 means the VM has what it needs (or more); above 150 is fully unhappy.

**Memory Happiness — Static Memory**
Proxied from host available memory utilization (fully happy ≤ 70%, fully unhappy ≥ 90%).

---

## Aggression Levels

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
| `Invoke-HvDRS` | Run a DRS balancing pass |
| `Enable-HvDRSMaintenance` | Create maintenance lock file (freeze migrations) |
| `Disable-HvDRSMaintenance` | Remove lock file (resume migrations) |
| `Get-HvDRSMaintenanceStatus` | Check whether maintenance mode is active |

---

## Requirements

- Windows Server 2016 or later
- Hyper-V role installed on all cluster nodes
- Windows Failover Clustering feature
- PowerShell 5.1 or later
- The account running the script must have **cluster administrative rights** and permission to perform Live Migrations

See [INSTALL.md](INSTALL.md) for full prerequisites and deployment instructions.  
See [USAGE.md](USAGE.md) for detailed examples, scheduling, and tuning guidance.  
See [TESTS.md](TESTS.md) for the test suite layout, coverage details, and how to run the tests.

---

## Planned Extensions

- **Storage DRS** — CSV utilization-based VM disk placement (separate module)
