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
$cfg.Run.Path         = './Tests/'
$cfg.Output.Verbosity = 'Detailed'
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
│   └── New-TestObjects.ps1              # Shared builder functions for test data
├── Measure-VmHappiness.Tests.ps1        # Unit tests for the happiness scoring algorithm
└── Find-MigrationCandidates.Tests.ps1  # Unit tests for the migration planning logic
```

### `Tests/Helpers/New-TestObjects.ps1`

Dot-sourced by both test files inside their `BeforeAll` blocks. Provides three builder functions with sensible defaults so each test only specifies the values relevant to that case:

| Function | Returns | Key parameters |
|---|---|---|
| `New-HostMetrics` | Host node PSCustomObject | `-Name`, `-CpuUtil`, `-TotalMemMB`, `-AvailMemMB`, `-LPs`, `-NetUtil` |
| `New-VmMetrics` | VM PSCustomObject | `-Name`, `-HostNode`, `-CpuUtil`, `-Procs`, `-MemAssignMB`, `-DynMem`, `-Pressure` |
| `New-Snapshot` | Cluster snapshot PSCustomObject | `-ClusterName`, `-Nodes`, `-VMs` |

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

Tests the migration planning logic in `Functions/Private/Find-MigrationCandidates.ps1`. All calls to `Get-ClusterOwnerNode` are mocked; the FailoverClusters module is not required.

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

## What Is Not Tested

The following require a live Hyper-V Failover Cluster and are not covered by the unit test suite:

| Component | Reason |
|---|---|
| `Get-ClusterSnapshot` | Calls `Invoke-Command` against real cluster nodes, `Get-Counter`, `Get-VM`, `Get-NetAdapterStatistics` |
| `Invoke-HvDRS` | Orchestration layer; correctness depends on real cluster state |
| `Move-ClusterVirtualMachineRole` | Requires cluster infrastructure |
| Maintenance helpers | Filesystem operations only; no non-trivial logic to unit test |

Integration testing of those components is best done with `Invoke-HvDRS -WhatIf` against a test cluster or a single-node Hyper-V lab.
