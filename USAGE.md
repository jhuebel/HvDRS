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
    [-RulesPath <String>]
    [-SoftRuleViolationPenalty <Single>]
    [-RuleComplianceBonus <Single>]
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
| `-RulesPath` | String | `$env:ProgramData\HvDRS\rules.json` | Path to the affinity/anti-affinity rule store; rule checking is skipped if the file does not exist |
| `-SoftRuleViolationPenalty` | Float (0–100) | 25.0 | Score penalty applied when a proposed move would break a soft rule |
| `-RuleComplianceBonus` | Float (0–100) | 25.0 | Score bonus applied when a proposed move would fix an existing soft rule violation |
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

### 3. Rule Violation Summary (if rules are configured)

When affinity rules are loaded, a violation table is printed before the VM scores:

```
── 1 Rule Violation(s) Detected — 1 hard, 0 soft ────────────────────────────

Rule        Type               Hard  VMs         Detail
----        ----               ----  ---         ------
DC-Anti     VmVmAntiAffinity   True  DC1, DC2    Anti-affinity rule 'DC-Anti': 'DC1', 'DC2' co-located on 'HV-NODE1'
```

### 4. Migration Recommendations

The `Trigger` column shows whether each migration was driven by rule compliance or by happiness scoring:

```
── 2 Migration Recommendation(s) ─────────────────────────────────────────────

VM     From      To        Score Before  Score After  Delta   CPU Δ          Mem Δ          Trigger
--     ----      --        ------------  -----------  -----   -----          -----          -------
DC1    HV-NODE1  HV-NODE2            88         90.0  +2.0   100.0 → 100.0  88.0 → 88.0   Compliance: Anti-affinity rule 'DC-Anti': ...
WEB-01 HV-NODE1  HV-NODE3            36         82.1  +46.1  0.0 → 100.0   72.0 → 72.0   Happiness
```

Compliance migrations appear first in the plan and are executed regardless of happiness threshold — they fix hard-rule violations. Happiness migrations follow and obey the normal aggression-level thresholds.

When running without `-WhatIf` or `-RecommendOnly`, migrations execute immediately after the table is printed.

---

## Invoke-HvStorageDRS

Balances Cluster Shared Volume utilization by live-migrating VM storage (VHDs + config) between CSVs while the VMs remain running.

### Syntax

```
Invoke-HvStorageDRS
    [-ClusterName <String>]
    [-AggressionLevel <Int32>]
    [-SampleCount <Int32>]
    [-SampleIntervalSeconds <Int32>]
    [-SpaceWeight <Single>]
    [-IoWeight <Single>]
    [-MinFreeGBReserve <Int32>]
    [-RecommendOnly]
    [-MaintenanceLockFile <String>]
    [-WhatIf]
    [-Verbose]
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ClusterName` | String | Local cluster | Target Failover Cluster name |
| `-AggressionLevel` | Int (1–5) | 3 | Migration sensitivity — same thresholds as Invoke-HvDRS |
| `-SampleCount` | Int | 3 | I/O counter samples to average per CSV. Set to 0 to skip I/O collection entirely |
| `-SampleIntervalSeconds` | Int | 5 | Seconds between I/O samples |
| `-SpaceWeight` | Float (0–1) | 0.7 | Weight of space happiness in combined CSV score |
| `-IoWeight` | Float (0–1) | 0.3 | Weight of I/O (latency) happiness. Silently dropped for CSVs where counters are unavailable |
| `-MinFreeGBReserve` | Int | 50 | Free space (GB) that must remain on the destination CSV after VHDs land |
| `-RecommendOnly` | Switch | — | Print the migration plan but never call Move-VMStorage |
| `-MaintenanceLockFile` | String | `$env:ProgramData\HvDRS\maintenance.lock` | Shared with Invoke-HvDRS; one lock file pauses both |
| `-WhatIf` | Switch | — | Standard PowerShell dry-run |
| `-Verbose` | Switch | — | Shows per-CSV counter collection progress |

### CSV Happiness scoring

**Space happiness** — based on free space percentage:

| Free % | Score |
|---|---|
| ≥ 40% | 100 |
| 20–40% | 50 + (pct – 20) × 2.5 |
| 10–20% | (pct – 10) × 5 |
| < 10% | 0 |

**IO happiness** — based on average disk transfer latency (`LatencyMs`). When latency counters are unavailable the IO weight is dropped and scoring falls back to space-only automatically.

| Latency | Score |
|---|---|
| ≤ 5 ms | 100 |
| 5–20 ms | 100 − (lat − 5) × 6.67 |
| > 20 ms | 0 |

### Common scenarios

```powershell
# Dry run — see what would be moved
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -WhatIf

# Space-only scoring (skip I/O counter collection)
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -SampleCount 0

# Aggressive rebalancing; require 100 GB headroom after each move
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -AggressionLevel 5 -MinFreeGBReserve 100

# Pure space scoring — ignore latency weighting entirely
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -SpaceWeight 1.0 -IoWeight 0.0
```

### Relationship to Invoke-HvDRS

`Invoke-HvDRS` and `Invoke-HvStorageDRS` are independent passes that can be run in sequence:

```powershell
# Rebalance compute placement, then storage placement
Invoke-HvDRS        -ClusterName 'PROD-CLUSTER'
Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER'
```

Both honour the same maintenance lock file, so `Enable-HvDRSMaintenance` suspends both.

### Understanding the output

A typical run produces three sections:

```
── CSV Summary ───────────────────────────────────────────────────────────────

CSV       Owner    Total GB  Used GB  Free GB  Used %  Read IOPS  Write IOPS  Latency ms
---       -----    --------  -------  -------  ------  ---------  ----------  ----------
Volume1   HV-NODE1   2048.0   1945.0    103.0    94.9       2450        1100        12.4
Volume2   HV-NODE2   2048.0    512.0   1536.0    25.0        340         120         2.1

── CSV Happiness Scores ──────────────────────────────────────────────────────

CSV      Space Happy  IO Happy  Score  Status
---      -----------  --------  -----  ------
Volume1          0.0      15.3    4.6  CRITICAL
Volume2        100.0     100.0  100.0  Healthy

── 2 Storage Migration Recommendation(s) ────────────────────────────────────

VM      Host      From CSV  To CSV   Data GB  Src Score    Dst Score    Src Free GB    Delta
--      ----      --------  ------   -------  ---------    ---------    -----------    -----
SQL-01  HV-NODE1  Volume1   Volume2   500.0   4.6 → 28.3  100.0 → 75.5  103 → 603   +23.7
APP-01  HV-NODE1  Volume1   Volume2   200.0   4.6 → 38.7   75.5 → 65.2  103 → 303   +34.1
```

---

## Affinity and Anti-Affinity Rules

HvDRS supports four rule types that constrain where VMs may run. Rules are stored in a JSON file (default: `$env:ProgramData\HvDRS\rules.json`) and are automatically loaded by `Invoke-HvDRS` each pass.

| Rule Type | Effect |
|---|---|
| `VmVmAffinity` | Keep the listed VMs on the same host |
| `VmVmAntiAffinity` | Keep the listed VMs on different hosts |
| `VmHostAffinity` | Run the listed VMs only on the specified hosts |
| `VmHostAntiAffinity` | Never run the listed VMs on the specified hosts |

### Hard vs soft rules

Add `-Enforced` when creating a rule to make it **hard**:

- **Hard rule**: HvDRS will *never* execute a migration that would break it, and will proactively schedule compliance migrations to fix existing violations.
- **Soft rule** (default): violations lower the candidate score by `-SoftRuleViolationPenalty` (default: 25 pts), but the migration is not blocked.

### Managing rules

#### Add a rule

```powershell
# Hard anti-affinity — domain controllers must never share a host
Add-HvDRSAffinityRule -Name 'DC Anti-Affinity' -Type VmVmAntiAffinity `
                      -VMs 'DC-01','DC-02' -Enforced

# Soft affinity — web tier VMs prefer to be together
Add-HvDRSAffinityRule -Name 'Web Tier Affinity' -Type VmVmAffinity `
                      -VMs 'WEB-01','WEB-02','WEB-03'

# Hard host affinity — SQL licensed only on nodes with SQL SA coverage
Add-HvDRSAffinityRule -Name 'SQL Licensing' -Type VmHostAffinity `
                      -VMs 'SQL-PROD-01' -Hosts 'HV-NODE1','HV-NODE2' -Enforced

# Hard host anti-affinity — dev VMs must never run on production nodes
Add-HvDRSAffinityRule -Name 'Dev Isolation' -Type VmHostAntiAffinity `
                      -VMs 'DEV-01','DEV-02' -Hosts 'HV-NODE1','HV-NODE2' -Enforced
```

#### List rules

```powershell
# All rules
Get-HvDRSAffinityRule

# Filter by type
Get-HvDRSAffinityRule -Type VmVmAntiAffinity

# Rules referencing a specific VM
Get-HvDRSAffinityRule -VmName 'SQL-PROD-01'

# Wildcard name search
Get-HvDRSAffinityRule -Name 'DC*'
```

#### Modify a rule

```powershell
$id = (Get-HvDRSAffinityRule -Name 'Web Tier Affinity').RuleId

# Add a VM to the group
Set-HvDRSAffinityRule -RuleId $id -AddVMs 'WEB-04'

# Promote from soft to hard
Set-HvDRSAffinityRule -RuleId $id -Enforced $true

# Rename
Set-HvDRSAffinityRule -RuleId $id -NewName 'Web Tier Co-location'
```

#### Remove a rule

```powershell
Remove-HvDRSAffinityRule -Name 'DC Anti-Affinity'
# or by ID
Remove-HvDRSAffinityRule -RuleId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

#### Check current compliance

```powershell
Test-HvDRSAffinityCompliance -ClusterName 'PROD-CLUSTER'
```

This collects a live snapshot and prints any violated rules without executing any migrations. It returns the violation objects so you can pipe them for further processing.

### How rules integrate with Invoke-HvDRS

Each `Invoke-HvDRS` pass runs two migration planning passes:

1. **Compliance pass** — scans for hard-rule violations and generates proactive migrations to fix them. These appear first in the plan with `Trigger: Compliance: <reason>`.
2. **Happiness pass** — scores each unhappy VM's candidate destinations, applying a penalty for soft-rule breaks and a bonus for soft-rule fixes, then selects the net-best option.

Hard-rule checks block any happiness-based migration that would create a new violation, regardless of how much happiness improvement it would deliver.

### Using a custom rule file

```powershell
# Manage rules in a project-specific file
Add-HvDRSAffinityRule -Name 'App Affinity' -Type VmVmAffinity `
                      -VMs 'APP-01','APP-02' -RulesPath D:\Config\my-rules.json

# Run HvDRS against the same file
Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -RulesPath D:\Config\my-rules.json
```

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
