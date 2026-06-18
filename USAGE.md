# HVDRS — Usage Guide

## Loading the Module

```powershell
Import-Module HVDRS
```

---

## Invoke-HvDRS

The primary function. Collects cluster metrics, scores VM happiness, and optionally executes live migrations.

### Syntax

```
Invoke-HvDRS
    [-ClusterName <String>]
    [-AggressionLevel <Int32>]
    [-SampleCount <Int32>]
    [-SampleIntervalSeconds <Int32>]
    [-CpuWeight <Single>]
    [-MemoryWeight <Single>]
    [-MaxDestinationNetworkUtil <Single>]
    [-DestinationMemoryReserveMB <Int32>]
    [-RecommendOnly]
    [-MaintenanceLockFile <String>]
    [-WhatIf]
    [-Verbose]
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ClusterName` | String | Local cluster | Target Failover Cluster name |
| `-AggressionLevel` | Int (1–5) | 3 | Migration sensitivity (see table below) |
| `-SampleCount` | Int | 5 | CPU counter samples to average per node |
| `-SampleIntervalSeconds` | Int | 2 | Seconds between CPU samples |
| `-CpuWeight` | Float (0–1) | 0.5 | CPU happiness weight in combined score |
| `-MemoryWeight` | Float (0–1) | 0.5 | Memory happiness weight in combined score |
| `-MaxDestinationNetworkUtil` | Float (0–100) | 70.0 | NIC utilization % above which a node is excluded as a migration target |
| `-DestinationMemoryReserveMB` | Int | 512 | Free memory (MB) that must remain on destination after migration |
| `-RecommendOnly` | Switch | — | Print recommendations but never execute migrations |
| `-MaintenanceLockFile` | String | `$env:ProgramData\HvDRS\maintenance.lock` | Path to the maintenance lock file checked each pass |
| `-WhatIf` | Switch | — | Standard PowerShell dry-run; shows what would be done |
| `-Verbose` | Switch | — | Prints per-node collection progress |

### Aggression Levels

| Level | Trigger threshold | Min improvement | Typical use |
|-------|------------------|-----------------|-------------|
| 1 | Score < 30 | +40 pts | Conservative — only severe imbalance |
| 2 | Score < 40 | +30 pts | Cautious |
| **3** | **Score < 50** | **+20 pts** | **Default — balanced** |
| 4 | Score < 60 | +15 pts | Proactive |
| 5 | Score < 70 | +10 pts | Aggressive — favor balance over stability |

---

## Common Scenarios

### Preview recommendations without migrating

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -WhatIf
```

`-WhatIf` is the standard PowerShell dry-run. HVDRS will collect metrics, print the node summary, VM happiness scores, and the migration recommendation table — then stop without calling `Move-ClusterVirtualMachineRole`.

### Auto-migrate at default settings

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER'
```

### Auto-migrate with verbose collection progress

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -Verbose
```

### Increase aggression to rebalance more proactively

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -AggressionLevel 4
```

### Weight memory more heavily than CPU

Useful for clusters where memory contention is the primary pain point (e.g., dense VDI or database workloads):

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -CpuWeight 0.3 -MemoryWeight 0.7
```

### Tighten the network gate

Prevent migrations to hosts already carrying significant network load:

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -MaxDestinationNetworkUtil 50
```

### Run as a monitoring-only pass (never migrates)

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -RecommendOnly
```

Unlike `-WhatIf` (which is typed interactively each time), `-RecommendOnly` is designed to be baked into a scheduled task action string to create a **permanent monitoring job** that logs happiness scores and recommendations without ever touching workloads.

### Increase sampling accuracy

Collect more CPU samples over a longer window before deciding:

```powershell
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -SampleCount 10 -SampleIntervalSeconds 5
```

---

## Maintenance Mode

Maintenance mode suspends all migration execution without modifying Task Scheduler or the scheduled task action. Drop the lock file to pause; delete it to resume.

### Enable maintenance mode

```powershell
Enable-HvDRSMaintenance -Reason 'Patch Tuesday patching window'
```

Output:
```
HvDRS maintenance mode ENABLED.
  Lock file : C:\ProgramData\HvDRS\maintenance.lock
  Reason    : Patch Tuesday patching window
  Run Disable-HvDRSMaintenance to resume automatic migrations.
```

While the lock file is present, `Invoke-HvDRS` still runs its full collection and scoring pass but prints:

```
[14:32:01] Maintenance lock active (C:\ProgramData\HvDRS\maintenance.lock). Metrics will be collected and scored but no migrations will run.
```

### Check maintenance status

```powershell
Get-HvDRSMaintenanceStatus
```

```
MaintenanceActive : True
LockFile          : C:\ProgramData\HvDRS\maintenance.lock
Reason            : Patch Tuesday patching window — enabled 2026-06-18 14:30:00
```

### Disable maintenance mode

```powershell
Disable-HvDRSMaintenance
```

```
HvDRS maintenance mode DISABLED. Automatic migrations will resume on the next pass.
```

### Use -WhatIf with maintenance helpers

```powershell
# Preview lock file creation without actually creating it
Enable-HvDRSMaintenance -Reason 'Test' -WhatIf
```

---

## Understanding the Output

A typical `Invoke-HvDRS` run produces three sections:

### 1. Node Summary

```
── Node Summary ──────────────────────────────────────────────────────────────

Node     CPU %  Mem Used  Mem Free   Net %  VMs
----     -----  --------  --------   -----  ---
HV-NODE1  78.4  81920 MB   6144 MB    12.3    8
HV-NODE2  31.2  49152 MB  38912 MB     4.1    4
HV-NODE3  42.8  61440 MB  26624 MB     6.7    6
```

### 2. VM Happiness Scores

```
── VM Happiness Scores ───────────────────────────────────────────────────────

VM            Host      CPU Happy  Mem Happy  Score  Status
--            ----      ---------  ---------  -----  ------
SQL-PROD-01   HV-NODE1       21.4       85.0   53.2  Uncomfortable
WEB-01        HV-NODE1        0.0       72.0   36.0  UNHAPPY
WEB-02        HV-NODE1        4.3       88.0   46.2  Uncomfortable
APP-01        HV-NODE2      100.0      100.0  100.0  Happy
DB-DEV-01     HV-NODE3       95.0       95.0   95.0  Happy
```

Scores are always sorted ascending (most unhappy first) so problems are immediately visible.

| Score range | Status label |
|---|---|
| 80–100 | Happy |
| 50–79 | Uncomfortable |
| 0–49 | UNHAPPY |

### 3. Migration Recommendations

```
── 2 Migration Recommendation(s) ─────────────────────────────────────────────

VM       From      To        Score Before  Score After  Delta  CPU Δ         Mem Δ
--       ----      --        ------------  -----------  -----  -----         -----
WEB-01   HV-NODE1  HV-NODE2            36         82.1  +46.1  0.0 → 100.0  72.0 → 72.0
WEB-02   HV-NODE1  HV-NODE3            46         78.4  +32.4  4.3 → 98.1   88.0 → 88.0
```

When running without `-WhatIf` or `-RecommendOnly`, migrations execute immediately after the table is printed.

---

## Tuning Guide

### The cluster looks balanced but VMs are still slow

Lower the aggression level. If most VMs are scoring 50–60, level 3 won't trigger because it only fires below 50. Try level 4 or 5 and monitor for excessive migration churn.

### Too many migrations are triggering on minor load spikes

Increase `SampleCount` and `SampleIntervalSeconds` to smooth out transient spikes before acting:

```powershell
Invoke-HvDRS -SampleCount 15 -SampleIntervalSeconds 4
```

Or raise the minimum improvement threshold by using a lower aggression level.

### Migrations are not considering a node that has capacity

Check two things:

1. **Network gate** — the node's NIC utilization may be above `-MaxDestinationNetworkUtil`. Check with:
   ```powershell
   Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -Verbose -WhatIf
   ```
   The Verbose output shows which nodes were excluded and why.

2. **Possible owners** — the VM's cluster group may restrict which nodes it can run on. Check with:
   ```powershell
   Get-ClusterOwnerNode -Cluster 'PROD-CLUSTER' -Group 'Virtual Machine MyVM'
   ```

### Dynamic Memory pressure counter is unavailable

If a VM's `\Hyper-V Dynamic Memory VM\Current Pressure` counter cannot be read (e.g., Dynamic Memory is not enabled, or the counter is momentarily unavailable), HVDRS assumes pressure = 100 (fully balanced). The VM will not be penalized for this — memory happiness falls back to the host memory utilization proxy.

### Memory happiness seems low for VMs with static RAM

Static-RAM VMs use host memory utilization as a proxy for memory happiness. If the host is heavily provisioned but VMs are not actually paging, consider enabling Dynamic Memory on those VMs so HVDRS can use the more accurate pressure counter.

---

## Example: Full Automation with Logging

```powershell
# Wrapper script for Task Scheduler
$logDir = 'C:\Logs\HvDRS'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }

$logFile = Join-Path $logDir ("hvdrs_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

Import-Module HVDRS

Invoke-HvDRS `
    -ClusterName    'PROD-CLUSTER' `
    -AggressionLevel 3 `
    -Verbose `
    *>> $logFile
```

Rotate or archive `$logDir` on a schedule to prevent unbounded growth.
