# HVDRS — Technical Architecture

This document describes how HVDRS is put together internally — module loading, the data flow through a DRS pass, what gets persisted to disk and why, and the shared patterns that recur across the compute and storage engines. It's aimed at contributors extending or debugging the module, not at end users running it — see [README.md](../README.md) for the feature tour and [USAGE.md](USAGE.md) for parameter-level usage. For test coverage and how to run the suite, see [TESTS.md](TESTS.md).

---

## Module loading and exports

`HVDRS.psm1` dot-sources every `.ps1` file under `Functions/Private/` and `Functions/Public/` at import time. It does **not** derive the export list from filenames — a public file's base name doesn't always match the function(s) it defines (`AffinityRules.ps1` defines four functions; `Maintenance.ps1` defines six). Instead, the loader parses each public file's AST to find every top-level `FunctionDefinitionAst` and calls `Export-ModuleMember -Function` with that full list.

This means a function is only actually importable when **two** independent lists agree:

1. `HVDRS.psm1`'s AST-derived export (automatic — any function defined in `Functions/Public/*.ps1` is included).
2. `HVDRS.psd1`'s `FunctionsToExport` array (manual — must be kept in sync by hand).

The manifest's list restricts the module-scope export down to its own entries, so a function present in (1) but missing from (2) silently doesn't export, and `Import-Module HVDRS` gives no error — it just doesn't have the cmdlet. This exact class of bug shipped twice in this module's history: 1.3.0 (missing `RootModule` in the manifest meant *nothing* exported) and 1.5.1 (a `$null`-collapse bug, different issue but same "looked fine until someone actually called it" symptom). **Whenever you add a new public function, add its name to `HVDRS.psd1`'s `FunctionsToExport` in the same change** — verify with:

```powershell
Import-Module ./HVDRS.psd1 -Force
Get-Command -Module HVDRS | Select-Object -ExpandProperty Name | Sort-Object
```

---

## Data flow per pass

Both `Invoke-HvDRS` and `Invoke-HvStorageDRS` follow the same shape — collect, score, plan, execute — with the newer features hooking in at specific points:

```
                    Invoke-HvDRS                              Invoke-HvStorageDRS
                    ────────────                              ───────────────────
Phase 1   Get-ClusterSnapshot                        Get-StorageSnapshot
              │                                          │
          [-TrendWindow > 1: Merge-HvDRSTrendSnapshot]    (no trend smoothing yet — see note below)
              │                                          │
Phase 2   Get-AffinityRuleSet (expands groups)       Get-AffinityRuleSet (storage rule types only)
          Get-HvDRSAutomationOverrideSet              Get-HvDRSAutomationOverrideSet
          Test-AffinityCompliance (report only)       Test-StorageAffinityCompliance (report only)
              │                                          │
Phase 3   Measure-VmHappiness (per VM)                Measure-CsvHappiness (per CSV)
              │                                          │
Phase 4   Find-MigrationCandidates                    Find-StorageMigrationCandidates
          (two-pass planner — see below)               (two-pass planner — see below)
              │                                          │
Phase 5   for each migration:                         for each migration:
            if Manual-pinned VM -> skip, count           if Manual-pinned VM -> skip, count
            else ShouldProcess -> Move-Cluster...         else ShouldProcess -> Move-VMStorage
              │                                          │
          Send-HvDRSNotification (-WebhookUrl/           Send-HvDRSNotification (same)
                                   -WriteEventLog)
          -PassThru -> structured recommendation objects  -PassThru -> structured recommendation objects
```

Trend smoothing (`-TrendWindow`) is currently implemented only for `Invoke-HvDRS`; `Invoke-HvStorageDRS` has no equivalent yet since CSV space/latency signals are steadier than per-VM CPU/memory-pressure in practice. If that changes, `Merge-HvDRSTrendSnapshot` would need a CSV-shaped counterpart (it currently assumes the compute snapshot shape — `Nodes`/`VMs` with `CpuUtilization`/`NetworkUtilization`/`MemoryPressure` fields).

Two related orchestration functions reuse pieces of this pipeline without running a full pass:

- **`Enter-HvDRSNodeMaintenance`** collects a snapshot and rules exactly like Phase 1–2 above, then evacuates one node's VMs via `Find-EvacuationDestination` (see below) instead of `Find-MigrationCandidates` — because it must place every VM on the node regardless of whether doing so improves happiness, whereas the normal planner only moves a VM when it clears the aggression-level improvement threshold.
- **`Get-HvDRSCapacityForecast`** does the same collection, then either calls `Find-EvacuationDestination` per VM (`-RemoveNode`) or a self-contained scoring loop against a synthetic node (`-AddNode` — see its own doc comment for why it can't reuse `Find-MigrationCandidates` directly: that function's possible-owner check queries the real cluster via `Get-ClusterOwnerNode`, which has no record of a node that doesn't exist yet).

---

## Persistent state on disk

Everything HVDRS persists lives under `Get-HvDRSDataRoot` (`$env:ProgramData` on Windows, the OS temp directory as a fallback for non-Windows dev/test environments), typically under a `HvDRS\` subfolder:

| File | Written by | Read by | Fail-soft contract |
|---|---|---|---|
| `rules.json` | `Add/Set/Remove-HvDRSAffinityRule` | `Get-AffinityRuleSet` (all consumers) | Missing/corrupt file → empty rule set (rule checking silently skipped) |
| `groups.json` | `Add/Set/Remove-HvDRSGroup` | `Get-AffinityRuleSet` (group expansion), `Get-HvDRSGroup` | Missing/corrupt file → no groups defined; rules behave as literal-only |
| `automation-overrides.json` | `Set/Remove-HvDRSVMAutomationLevel` | `Invoke-HvDRS`/`Invoke-HvStorageDRS` (execution gating), `Get-HvDRSVMAutomationLevel` | Missing/corrupt file → no overrides; every VM is FullyAutomated |
| `maintenance.lock` | `Enable/Disable-HvDRSMaintenance` | `Invoke-HvDRS`/`Invoke-HvStorageDRS` (checked via `Test-Path`, not JSON-parsed) | Absence means "not in maintenance" — this is the normal state, not a failure |
| `history\<ClusterName>.json` | `Merge-HvDRSTrendSnapshot` | Same function, next pass | Missing/corrupt file → fresh single-entry window (current snapshot only) |

All five follow the load pattern `Get-AffinityRuleSet` established first: `Test-Path` → if absent, return an empty result immediately; otherwise `Get-Content -Raw | ConvertFrom-Json` inside a `try/catch`, with any parse failure also degrading to an empty result via `Write-Warning` rather than throwing. A missing or corrupt file is never a hard error anywhere in this module — it's treated as "nothing configured yet."

A subtlety worth knowing if you touch any of these loaders: PowerShell collapses both a zero-element array *and* certain single-element results to something other than a plain multi-element array when they cross a function boundary or an `if/else`-as-expression assignment. The `,@()` prefix on every empty-result `return` in this codebase exists specifically to stop the zero-element case from becoming `$null`. The single-element case is subtler — assigning the result of an `if { X } else { Y }` block re-applies PowerShell's "one emitted object doesn't get re-wrapped in an array" rule to whichever branch actually ran, *regardless of whether X or Y was already an array*. `Get-AffinityRuleSet`'s group-expansion logic guards against this by wrapping the whole `if` expression in an outer `@(...)` (`$vmGroups = @( if (...) { $rule.VMGroups } )`) rather than wrapping only the true-branch's value — the latter still collapses when the branch itself emits exactly one item.

---

## The two-pass planner pattern

`Find-MigrationCandidates` (compute) and `Find-StorageMigrationCandidates` (storage) share a structure, duplicated rather than abstracted into a shared function since compute and storage have different scoring inputs (CPU/memory vs. space/latency) and different destination constraints (network gate + memory reserve vs. free-space reserve):

1. **Compliance pass** — every *enforced* rule currently violated gets a proactive fix: the best (VM, destination) pair that resolves it without introducing a new hard violation, evaluated ahead of and independent of any happiness threshold. Compliance migrations are always included in the plan.
2. **Happiness pass** — VMs/CSVs below the aggression-level threshold are evaluated against every remaining candidate destination, with soft-rule violations penalizing and soft-rule fixes bonusing the projected score. Only moves clearing the aggression level's minimum-improvement threshold make the plan.

Both passes maintain **simulated state** (a `$simNodes`/`$simCsvs` hashtable) that's updated after each planned migration, so a second migration in the same pass doesn't double-book a destination that the first migration already filled.

`Find-EvacuationDestination` factors the destination-selection half of pass 2's logic (network gate, memory reserve, possible-owner constraints, rule-impact scoring) out of `Find-MigrationCandidates` into its own function, but with the improvement threshold removed — a node being evacuated *must* place its VMs somewhere, not just where doing so happens to help. It's shared by two callers that both need "place this one VM, regardless of threshold" rather than "plan a whole rebalance":

- `Enter-HvDRSNodeMaintenance`, for real evacuation.
- `Get-HvDRSCapacityForecast -RemoveNode`, for simulation only.

To support being called in a loop across multiple VMs on the same draining node, `Find-EvacuationDestination` has a documented side effect: on a successful match, it mutates the chosen destination node's simulated `CpuUtilization`/`AvailableMemoryMB` in place (on the `-Snapshot` object passed in) and sets the VM's `HostNode` to the new destination — the same greedy-update idea `Find-MigrationCandidates` uses internally, just exposed as a side effect on shared state instead of a private closure, since here the caller (not the function itself) owns the loop over multiple VMs.

---

## Group resolution

VM/Host/CSV groups (`Add-HvDRSGroup` et al., stored in `groups.json`) resolve **dynamically at read time**, not by denormalizing group members into each rule at write time. The integration point is `Get-AffinityRuleSet`: after loading raw rules from `rules.json`, it loads `groups.json` and unions each rule's literal `VMs`/`Hosts`/`CSVs` with the current members of any group its `VMGroups`/`HostGroups`/`CSVGroups` properties reference — then returns the expanded rule. Every downstream consumer (`Test-AffinityCompliance`, `Get-MigrationRuleImpact`, `Find-MigrationCandidates`, and the storage equivalents) only ever reads `$rule.VMs`/`.Hosts`/`.CSVs` and needed zero changes to support groups.

This has one important consequence: **`Get-AffinityRuleSet`'s default behavior is not safe to use for a load-modify-resave cycle.** If a rule referencing a group were loaded with expansion, mutated, and saved back, the expanded (literal + group members) list would get baked into `rules.json` permanently — the next resave would do it again, and group edits would stop propagating. `Add/Remove/Set-HvDRSAffinityRule` (which all load the full rule list, change one rule, and resave the whole file) call `Get-AffinityRuleSet -SkipGroupExpansion` for exactly this reason — they operate on the raw, unexpanded rules. Read-only consumers (`Get-HvDRSAffinityRule`, `Test-HvDRSAffinityCompliance`, `Invoke-HvDRS`/`Invoke-HvStorageDRS`) use the default (expanding) call.

If you add a new rule-mutating function, it needs `-SkipGroupExpansion` too — forgetting it wouldn't fail any test that only checks expansion *works*, only one that checks a resave doesn't corrupt the store (see the `AffinityRules.Tests.ps1` test "does not persist expanded group members back into the rule store on a subsequent edit").

---

## ProPack boundary

`ProPack/` is a fully optional add-on — installing or never installing it leaves the core module's behavior identical. It surfaces recommendations as VMM PRO Tips without ever executing a migration itself, for **both** engines now:

```
Invoke-HvDRS -RecommendOnly -PassThru          Invoke-HvStorageDRS -RecommendOnly -PassThru
        │                                              │
        ▼                                              ▼
ConvertTo-HvDrsProTip                          ConvertTo-HvDrsStorageProTip
        │                                              │
        ▼                                              ▼
Resolve-VmmIdentity                            Resolve-VmmStorageIdentity
 (VMId/node → SCVirtualMachine/SCVMHost)         (VMId/CSV name → SCVirtualMachine/storage volume)
        │                                              │
        ▼                                              ▼
Invoke-HvDrsProTipProbe                        Invoke-HvDrsStorageProTipProbe
        │                                              │
        └──────────────────┬───────────────────────────┘
                            ▼
              SCOM property bag → UnitMonitor → Alert → ProTip insertion Rule
                            │
                            ▼
        Admin approves in VMM console → VMM's own Move-SCVirtualMachine /
                                          storage-move job executes it
```

Both `Resolve-VmmIdentity` and `Resolve-VmmStorageIdentity` join on the VM's Hyper-V GUID (`VMId`), never on display name — VMM environments commonly have duplicate names across clouds/host groups — and both fail soft (`Resolved = $false` + `FailureReason`) rather than throwing, so one unresolvable recommendation in a batch doesn't block the others. `New-HvDrsScriptApi` (defined once, in `Invoke-HvDrsProTipProbe.ps1`) wraps the `MOM.ScriptAPI` COM object so both probe functions are unit-testable without a real SCOM agent; the storage probe's script body in the Management Pack dot-sources the compute probe script purely to reuse that wrapper. See [ProPack/PROPACK.md](../ProPack/PROPACK.md) for the full installation/configuration/troubleshooting reference and the parallel compute/storage sections of the Management Pack XML.

---

## Cross-references

- [README.md](../README.md) — feature tour, comparison with SCVMM Dynamic Optimization, module layout.
- [docs/USAGE.md](USAGE.md) — parameter tables and worked examples for every public function.
- [docs/TESTS.md](TESTS.md) — test layout, per-file coverage, and what's intentionally not covered (anything requiring a live cluster or SCOM/VMM lab).
- [ProPack/PROPACK.md](../ProPack/PROPACK.md) — the optional VMM PRO Tips add-on in detail.
