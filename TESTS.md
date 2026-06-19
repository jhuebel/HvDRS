# HVDRS — Test Suite

The test suite uses [Pester 5](https://pester.dev) and targets the pure-logic private functions that do not require a live Hyper-V cluster. Tests run on any Windows machine (or CI agent) with PowerShell 5.1+ and Pester 5 installed.

---

## Prerequisites

Install Pester 5 if it is not already present:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

> **Note:** Windows ships with Pester 3.x in `C:\Windows\System32\WindowsPowerShell\v1.0\Modules\`. The `-SkipPublisherCheck` flag is required to install the newer version from the PowerShell Gallery alongside it.

The FailoverClusters module is **not required** to run the tests. Any cluster cmdlets used by the code under test are stubbed and mocked within the test files.

---

## Running the Tests

### Run all tests

```powershell
Invoke-Pester ./Tests/ -Output Detailed
```

### Run a single test file

```powershell
Invoke-Pester ./Tests/Measure-VmHappiness.Tests.ps1 -Output Detailed
```

### Run only tests matching a name pattern

```powershell
Invoke-Pester ./Tests/ -Output Detailed -FullNameFilter '*CPU Happiness*'
```

### Suppress per-test output (summary only)

```powershell
Invoke-Pester ./Tests/ -Output Normal
```

### Produce a NUnit XML report (for CI integration)

```powershell
$cfg = New-PesterConfiguration
$cfg.Run.Path              = './Tests/'
$cfg.Output.Verbosity      = 'Detailed'
$cfg.TestResult.Enabled    = $true
$cfg.TestResult.OutputPath = './TestResults.xml'
$cfg.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration $cfg
```

---

## Test Layout

```
Tests/
├── Helpers/
│   └── New-TestObjects.ps1                   # Shared builder functions for test data
├── Measure-VmHappiness.Tests.ps1             # VM happiness scoring algorithm
├── Find-MigrationCandidates.Tests.ps1        # Compute migration planning logic
├── Get-MigrationRuleImpact.Tests.ps1         # Per-migration rule impact evaluation
├── Test-AffinityCompliance.Tests.ps1         # Current-placement violation detection
├── AffinityRules.Tests.ps1                   # Affinity rule CRUD + per-cluster scoping
├── Measure-CsvHappiness.Tests.ps1            # CSV happiness scoring algorithm
└── Find-StorageMigrationCandidates.Tests.ps1 # Storage migration planning logic
```

### `Tests/Helpers/New-TestObjects.ps1`

Dot-sourced by test files inside their `BeforeAll` blocks. Provides builder functions with sensible defaults so each test only specifies the values relevant to that case:

| Function | Returns | Key parameters |
|---|---|---|
| `New-HostMetrics` | Host node PSCustomObject | `-Name`, `-CpuUtil`, `-TotalMemMB`, `-AvailMemMB`, `-LPs`, `-NetUtil` |
| `New-VmMetrics` | VM PSCustomObject | `-Name`, `-HostNode`, `-CpuUtil`, `-Procs`, `-MemAssignMB`, `-DynMem`, `-Pressure` |
| `New-Snapshot` | Cluster snapshot PSCustomObject | `-ClusterName`, `-Nodes`, `-VMs` |
| `New-CsvMetrics` | CSV PSCustomObject | `-Name`, `-Path`, `-OwnerNode`, `-TotalGB`, `-FreeGB`; optional `-LatencyMs`, `-ReadIOPS`, `-WriteIOPS` |
| `New-VmStorageMetrics` | VM storage PSCustomObject | `-Name`, `-HostNode`, `-PrimaryCSV`, `-TotalVhdGB`; generates VHDs array automatically |
| `New-StorageSnapshot` | Storage snapshot PSCustomObject | `-ClusterName`, `-CSVs`, `-VMs` |

---

## Test Coverage

### `Measure-VmHappiness.Tests.ps1` — 22 tests

Tests the happiness scoring formula in `Functions/Private/Measure-VmHappiness.ps1`.

**CPU Happiness** (6 tests)

Verifies the linear stress ramp: stress is 0 when host CPU ≤ 70%, rises to 1.0 at 100%.
`cpuHappiness = max(0, 100 − stress × vmCpuUtil)`

| Scenario | Host CPU | VM CPU | Expected |
|---|---|---|---|
| Host well below threshold | 50% | 80% | 100.0 |
| Host exactly at threshold | 70% | 100% | 100.0 |
| Host moderately stressed | 85% | 80% | 60.0 |
| Host fully loaded, VM half demanding | 100% | 50% | 50.0 |
| Host fully loaded, VM fully demanding | 100% | 100% | 0.0 |
| Host fully loaded, VM idle | 100% | 0% | 100.0 |

**Memory Happiness — Dynamic Memory** (5 tests)

Verifies the pressure band: `memHappiness = 100 − (pressure − 100) × 2` for pressure in [100, 150].

| Pressure | Expected |
|---|---|
| 80 (surplus) | 100.0 |
| 100 (balanced) | 100.0 |
| 125 (midpoint) | 50.0 |
| 150 (upper boundary) | 0.0 |
| 200 (above boundary) | 0.0 |

**Memory Happiness — Static Memory** (5 tests)

Verifies the host memory utilization proxy: `memHappiness = 100 − (util − 70) × 5` for util in [70%, 90%].

| Host mem utilization | Expected |
|---|---|
| 40% | 100.0 |
| 70% (boundary) | 100.0 |
| 80% | 50.0 |
| 90% (boundary) | 0.0 |
| 95% | 0.0 |

**Combined Score** (6 tests)

Verifies weight normalization: `score = (cpuHappy × cpuWeight + memHappy × memWeight) / (cpuWeight + memWeight)`

| CPU happy | Mem happy | Weights (cpu/mem) | Expected |
|---|---|---|---|
| 100 | 100 | 0.5 / 0.5 | 100.0 |
| 60 | 40 | 0.5 / 0.5 | 50.0 |
| 60 | 40 | 0.3 / 0.7 | 53.0 |
| 50 | 100 | 1.0 / 0.0 | 50.0 |
| 0 | 50 | 0.0 / 1.0 | 50.0 |
| 0 | 0 | 0.5 / 0.5 | 0.0 |

**Output Object** (4 tests)

Verifies property names (`VMName`, `HostNode`, `CpuHappiness`, `MemHappiness`, `HappinessScore`), value propagation from inputs, bounds (0–100), and rounding to one decimal place.

---

### `Find-MigrationCandidates.Tests.ps1` — 18 tests

Tests the two-pass migration planning logic in `Functions/Private/Find-MigrationCandidates.ps1`. All calls to `Get-ClusterOwnerNode` are mocked; the FailoverClusters module is not required.

**Basic Triggering** (2 tests)

- An unhappy VM (score < aggression threshold) produces a migration recommendation.
- All-happy VMs produce no recommendations.

**Network-Aware Filtering** (3 tests)

- A destination node at or above `-MaxDestinationNetworkUtil` (default 70%) is excluded.
- A destination node below the gate is included.
- A custom gate value (e.g. 50%) is respected.

**Memory Constraints** (2 tests)

- A destination that would leave less than `-DestinationMemoryReserveMB` (default 512 MB) free after migration is excluded.
- A destination with sufficient post-migration headroom is included.

**Cluster Ownership Constraints** (2 tests)

- When `Get-ClusterOwnerNode` returns a restricted owner list, only listed nodes are considered as destinations.
- When `Get-ClusterOwnerNode` throws (group not found, module absent), all cluster nodes are treated as eligible.

**Aggression Levels** (4 tests)

- A VM with score=65 is **not** migrated at level 4 (threshold=60; 65 is not below 60).
- The same VM **is** migrated at level 5 (threshold=70; 65 < 70).
- A VM with a small available improvement (12.5 pts) is **not** migrated at level 1 (minimum +40).
- The same VM **is** migrated at level 5 (minimum +10; 12.5 ≥ 10).

**Migration Plan Output** (9 tests)

Verifies all fields on the returned migration object: `VMName`, `VMId`, `SourceNode`, `DestinationNode`, `CurrentScore`, `ProjectedScore`, `Improvement`, `CpuHappinessBefore`, `MemHappinessBefore`, `CpuHappinessAfter`, `MemHappinessAfter`. Also verifies that when multiple destinations exist, the one offering the greatest improvement is chosen.

**Greedy State Update** (2 tests)

- Two equally unhappy VMs on a source node; destination has memory for only one. After the first migration is planned and the simulated `AvailableMemoryMB` on the destination is decremented, the second VM is correctly excluded (post-migration free memory would fall below the reserve).
- No VM appears in the migration list more than once.

---

### `Get-MigrationRuleImpact.Tests.ps1` — 18 tests

Tests the rule-impact evaluation logic in `Functions/Private/Get-MigrationRuleImpact.ps1`. Given a proposed (VM, destination) pair and the current snapshot, the function simulates post-migration placement and classifies each affected rule as Break, Fix, or Neutral.

**Empty / no-op cases** (3 tests)

- Empty `RuleSet` → all-false result.
- Null `RuleSet` → all-false result.
- No rule references the migrating VM → all-false result.

**VmVmAffinity** (4 tests)

| Scenario | Expected |
|---|---|
| Moving VM off shared host (rule satisfied) | `HasHardViolation=true` |
| Same move, non-enforced rule | `HasSoftViolation=true` |
| Moving VM onto host where peers already reside (rule violated) | `FixesViolation=true` |
| Moving to third node while rule is already violated | Neutral (all false) |

**VmVmAntiAffinity** (4 tests)

| Scenario | Expected |
|---|---|
| Moving VM onto host already running a peer (rule satisfied) | `HasHardViolation=true` |
| Same move, non-enforced rule | `HasSoftViolation=true` |
| Moving co-located VM to a unique host (rule violated) | `FixesViolation=true` |
| Moving VM to empty node, rule already satisfied | Neutral |

**VmHostAffinity** (3 tests)

- Moving VM off allowed hosts → `HasHardViolation=true`.
- Moving VM onto an allowed host (currently on non-allowed) → `FixesViolation=true`.
- Moving between two allowed hosts → Neutral.

**VmHostAntiAffinity** (3 tests)

- Moving VM onto an excluded host → `HasHardViolation=true`.
- Moving VM off an excluded host → `FixesViolation=true`.
- Moving VM between two non-excluded hosts → Neutral.

**Output object structure** (2 tests)

- Result always contains all six properties (`HasHardViolation`, `HasSoftViolation`, `FixesViolation`, `HardReasons`, `SoftReasons`, `FixReasons`).
- `HardReasons` is non-empty when `HasHardViolation` is true; `SoftReasons` is empty.

---

### `Test-AffinityCompliance.Tests.ps1` — 16 tests

Tests current-placement violation detection in `Functions/Private/Test-AffinityCompliance.ps1`. Given a snapshot and rule set, it returns one violation record per broken rule instance.

**No-op cases** (3 tests)

- Empty or null `RuleSet` → empty result.
- Rules whose VMs are all offline (not in snapshot) → skipped.

**VmVmAffinity** (3 tests)

- Co-located group → no violation.
- Group split across two nodes → one violation containing both VMs.
- Offline member ignored; online members on same node → no violation.

**VmVmAntiAffinity** (3 tests)

- All VMs on separate nodes → no violation.
- Two VMs co-located → one violation listing both.
- Two separate conflicting pairs → two violations.

**VmHostAffinity** (2 tests)

- VM on an allowed host → no violation.
- VM on a non-allowed host → one violation per offending VM.

**VmHostAntiAffinity** (2 tests)

- VM not on any excluded host → no violation.
- VM on an excluded host → one violation.

**Output fields** (3 tests)

- Each violation record contains `RuleId`, `RuleName`, `Type`, `Enforced`, `VMs`, `Description`.
- `Enforced` flag mirrors the source rule for both hard and soft rules.

---

### `AffinityRules.Tests.ps1` — 36 tests

Tests the public CRUD functions in `Functions/Public/AffinityRules.ps1` and the private `Get-AffinityRuleSet` filter. Uses a per-test temporary JSON file so the real rule store at `$env:ProgramData\HvDRS\rules.json` is never touched.

**Add-HvDRSAffinityRule** (11 tests)

| Scenario | Verified |
|---|---|
| Create a VmVmAffinity rule | Rule persisted, Name and Type correct |
| Rule stores ClusterName | `ClusterName` property matches `-ClusterName` argument |
| New rule gets a unique GUID | `RuleId` parseable as `[System.Guid]` |
| Default `Enforced` is `$false` | Confirmed without `-Enforced` switch |
| `-Enforced` switch sets `$true` | Confirmed |
| VmVmAffinity with fewer than 2 VMs | Throws |
| VmHostAffinity with no `-Hosts` | Throws |
| Duplicate name in same cluster | Warning emitted, second rule not stored |
| Same name allowed in different cluster | Both rules stored; total count = 2 |
| Multiple rules in same cluster | Count = 2 |
| `-WhatIf` | No file created |

**Get-HvDRSAffinityRule** (8 tests)

- Returns all rules across all clusters when `-ClusterName` is omitted.
- Returns only the specified cluster's rules when `-ClusterName` is provided.
- Filters by exact `Name` (ByName parameter set).
- Supports wildcards in `Name`.
- Filters by `Type`.
- Filters by `VmName`.
- Filters by `RuleId`.
- Returns empty array when no rules match.

**Remove-HvDRSAffinityRule** (5 tests)

- Removes by `Name`; remaining rules intact.
- Removes by `RuleId`.
- Removes only from the specified cluster when `-ClusterName` is given; sibling cluster rule untouched.
- Non-existent name → warning, no error, count unchanged.
- `-WhatIf` → no removal.

**Set-HvDRSAffinityRule** (9 tests)

- `-NewName` renames the rule.
- `-Description` replaces description text.
- `-Enforced $true` sets enforcement.
- `-AddVMs` appends without duplicating.
- `-RemoveVMs` removes listed members.
- Removing members below minimum count → throws.
- Unknown `RuleId` → warning, no change.
- `-WhatIf` → no change persisted.
- `ClusterName` is preserved on the rule after editing.

**Per-cluster scoping** (3 tests)

- Rules for different clusters coexist in the same file without interference; `Get-HvDRSAffinityRule -ClusterName` returns only that cluster's subset.
- Removing a rule from one cluster does not affect another cluster's rule with the same name.
- Private `Get-AffinityRuleSet -ClusterName` returns only the matching cluster's rules.

---

### `Measure-CsvHappiness.Tests.ps1` — 20 tests

Tests the CSV happiness scoring formula in `Functions/Private/Measure-CsvHappiness.ps1`.

**Space Happiness** (7 tests)

| Free space | Formula | Expected |
|---|---|---|
| ≥ 40% (e.g. 60%) | 100 | 100.0 |
| Exactly 40% | 100 | 100.0 |
| 30% (midpoint 20–40%) | 50 + (30-20)×2.5 | 75.0 |
| Exactly 20% | 50 + 0 | 50.0 |
| 15% (midpoint 10–20%) | (15-10)×5 | 25.0 |
| Exactly 10% | (10-10)×5 | 0.0 |
| < 10% (e.g. 5%) | clamped | 0.0 |

**IO Happiness — latency** (6 tests)

| Latency | Expected |
|---|---|
| ≤ 5 ms (e.g. 1.5 ms) | 100.0 |
| Exactly 5 ms | 100.0 |
| 12.5 ms (midpoint 5–20 ms) | ≈ 50.0 |
| Exactly 20 ms | ≈ 0.0 |
| > 20 ms (e.g. 35 ms) | 0.0 |
| LatencyMs is null | IoHappiness is null |

**Fallback to space-only when no I/O data** (2 tests)

- `HappinessScore` equals `SpaceHappiness` when `LatencyMs` is null, regardless of `IoWeight`.
- A CSV without I/O data scores higher than one with bad latency at the same free-space level.

**Combined score with weights** (5 tests)

- Default weights (0.7/0.3) produce correct weighted average.
- `IoWeight=0` → pure space score even with bad latency.
- `SpaceWeight=0` with latency data → pure I/O score.
- Both components at 100 → 100.0.
- Both components at 0 → 0.0.

**Output object** (4 tests)

- All four properties present (`CsvName`, `SpaceHappiness`, `IoHappiness`, `HappinessScore`).
- `CsvName` echoes input name.
- `HappinessScore` has at most one decimal place.
- Score is bounded within 0–100.

---

### `Find-StorageMigrationCandidates.Tests.ps1` — 15 tests

Tests the storage migration planning logic in `Functions/Private/Find-StorageMigrationCandidates.ps1`. No cluster or Hyper-V cmdlets are called.

**Basic triggering** (3 tests)

- Unhappy CSV with a movable VM → migration recommended.
- All CSVs happy → no recommendations.
- Unhappy CSV but no VMs → no recommendations.

**MinFreeGBReserve constraint** (2 tests)

- Destination excluded when `FreeGB − vm.TotalVhdGB < MinFreeGBReserve`.
- Destination included when headroom meets reserve.

**Aggression levels** (3 tests)

- CSV at score 62.5 not triggered at level 3 (threshold=50; 62.5 > 50).
- Same CSV triggered at level 5 (threshold=70; 62.5 < 70).
- Trivially small VHD produces too little improvement to meet level-1 minimum (+40 pts).

**Destination selection** (1 test)

- When multiple valid destinations exist, the planner selects one and produces a single candidate.

**Greedy state update** (2 tests)

- Same VM never appears twice in the migration list.
- After first VM is planned, simulated destination headroom is reduced; second VM of same size is correctly excluded.

**Output object fields** (9 tests)

Verifies all fields on the returned migration object: `VMName`, `HostNode`, `SourceCSV`, `SourceCSVName`, `DestinationCSV`, `DestinationCSVName`, `TotalVhdGB`, `SourceFreeGBBefore/After`, `DestFreeGBBefore/After`, `SourceScoreBefore/After`, `DestScoreBefore/After`, `Improvement`. Also verifies sign invariants: `Improvement > 0`, `SourceScoreAfter > SourceScoreBefore`, free-GB accounting identity.

---

## What Is Not Tested

The following require a live Hyper-V Failover Cluster and are not covered by the unit test suite:

| Component | Reason |
|---|---|
| `Get-ClusterSnapshot` | Calls `Invoke-Command` against real cluster nodes, `Get-Counter`, `Get-VM`, `Get-NetAdapterStatistics` |
| `Invoke-HvDRS` | Orchestration layer; correctness depends on real cluster state |
| `Move-ClusterVirtualMachineRole` | Requires cluster infrastructure |
| `Get-StorageSnapshot` | Calls `Get-ClusterSharedVolume`, `Get-VM`, `Get-VHD`, `Get-Counter` against live cluster |
| `Invoke-HvStorageDRS` | Orchestration layer; correctness depends on real cluster and CSV state |
| `Move-VMStorage` | Requires cluster infrastructure and CSV storage |
| Maintenance helpers | Filesystem operations only; no non-trivial logic to unit test |

Integration testing of those components is best done with `-WhatIf` or `-RecommendOnly` against a test cluster or a single-node Hyper-V lab.
