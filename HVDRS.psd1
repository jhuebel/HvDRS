@{
    RootModule        = 'HVDRS.psm1'
    ModuleVersion     = '1.7.0'
    GUID              = 'a3f2c1d4-8e7b-4a9f-b5c6-d2e1f0a3b4c5'
    Author            = 'Jason Huebel'
    CompanyName       = ''
    Copyright         = '(c) 2026 Jason Huebel. Licensed under the MIT License.'
    Description       = 'Hyper-V Distributed Resource Scheduler — VM Happiness-based compute and storage load balancing for Failover Clusters, with affinity/anti-affinity rule enforcement'
    PowerShellVersion = '5.1'
    # FailoverClusters and Hyper-V are Windows Server role modules that cannot be
    # installed from the gallery — declared as ExternalModuleDependencies instead.
    FunctionsToExport = @(
        'Invoke-HvDRS',
        'Get-HvDRSCluster',
        'Enable-HvDRSMaintenance',
        'Disable-HvDRSMaintenance',
        'Get-HvDRSMaintenanceStatus',
        'Enter-HvDRSNodeMaintenance',
        'Exit-HvDRSNodeMaintenance',
        'Get-HvDRSNodeMaintenanceStatus',
        'Add-HvDRSAffinityRule',
        'Get-HvDRSAffinityRule',
        'Remove-HvDRSAffinityRule',
        'Set-HvDRSAffinityRule',
        'Test-HvDRSAffinityCompliance',
        'Test-HvDRSStorageAffinityCompliance',
        'Add-HvDRSGroup',
        'Get-HvDRSGroup',
        'Remove-HvDRSGroup',
        'Set-HvDRSGroup',
        'Set-HvDRSVMAutomationLevel',
        'Get-HvDRSVMAutomationLevel',
        'Remove-HvDRSVMAutomationLevel',
        'Get-HvDRSCapacityForecast',
        'Invoke-HvStorageDRS'
    )
    PrivateData       = @{
        PSData = @{
            Tags        = @(
                'Hyper-V', 'HyperV', 'DRS', 'FailoverCluster', 'LoadBalancing',
                'VirtualMachine', 'VM', 'LiveMigration', 'StorageMigration',
                'CSV', 'ClusterSharedVolume', 'Affinity', 'WindowsServer', 'Automation'
            )
            ExternalModuleDependencies = @('FailoverClusters', 'Hyper-V')
            LicenseUri  = 'https://github.com/jhuebel/HvDRS/blob/main/LICENSE'
            ProjectUri  = 'https://github.com/jhuebel/HvDRS'
            ReleaseNotes = @'
## 1.7.0
- Fixed several correctness bugs in the compute and storage DRS planners:
  rule-impact checks now use a live simulated placement, so a second
  migration planned in the same pass sees the moves the first one already
  made instead of stale snapshot data. A hard affinity/anti-affinity
  violation spanning 3 or more VMs (e.g. three VMs sharing one host under an
  enforced anti-affinity rule) is now actually resolved, with as many moves
  as needed, instead of being reported unfixable forever because no single
  move could fully satisfy it. The storage happiness planner no longer
  "fixes" one CSV by pushing another below the aggression threshold, and
  keeps moving VMs off a badly-unhappy CSV until it recovers instead of
  stopping after one move. VMs pinned to Manual automation are now excluded
  from planning entirely, not just skipped at execution after already being
  chosen as the fix for a hard-rule violation.
- Fixed the possible-owner lookup querying the wrong cluster object
  (Get-ClusterOwnerNode -Group instead of -Resource), which meant the
  possible-owner constraint documented in the README never actually applied.
- Fixed Invoke-HvStorageDRS's ConfirmImpact ('High') blocking scheduled
  -NonInteractive runs, and storage moves colliding when two VMs' VHDs
  shared a file name — moves now land in a per-VM destination folder.
- Fixed the Network-Aware gate double-counting Hyper-V virtual switch
  adapter traffic (now -Physical-only), CSV path matching colliding between
  e.g. "Volume1" and "Volume10", and per-VHD size using the maximum virtual
  size instead of actual on-disk footprint.
- Enter-HvDRSNodeMaintenance now holds the HVDRS maintenance lock for the
  duration of an evacuation — closing a race with a concurrently-scheduled
  Invoke-HvDRS/Invoke-HvStorageDRS pass — via a new -MaintenanceLockFile
  parameter, and reports any stopped VM or non-VM cluster role left on the
  node via a new OtherRolesOnNode property instead of silently ignoring them.
- Fixed -TrendWindow smoothing persisting to the shared history file under
  -WhatIf, and added an automatic history reset after a pass that actually
  migrates a VM so smoothing doesn't keep pulling toward a placement that no
  longer exists.
- Fixed Test-HvDRSAffinityCompliance / Test-HvDRSStorageAffinityCompliance
  leaking Format-Table's own formatting objects into their return value.
- The rules/groups/automation-overrides JSON stores now fail closed (throw)
  when the file exists but is corrupt, instead of silently treating it as
  "nothing configured" — which previously risked the next rule/group/
  override edit overwriting the corrupt file and permanently losing
  everything in it.
- Expanded the test suite substantially to cover all of the above.

## 1.6.1
- Fixed latent bugs, of the same class fixed in 1.5.1, that only surfaced under
  Set-StrictMode (which the publish pipeline enables) and were caught while
  preparing this release:
  - Invoke-HvStorageDRS and Test-HvDRSStorageAffinityCompliance both piped
    Get-AffinityRuleSet's output directly into Where-Object to filter storage
    rule types. When no rules are configured at all, this threw under strict
    mode — PowerShell enumerates the ",@()" empty-result wrapper as a single
    pipeline item when piped directly (rather than assigned to a variable
    first), so the Where-Object script block's $_.Type access failed. Both
    call sites now capture into a variable before filtering.
  - Get-HvDRSVMAutomationLevel's no-"-VMName" branch returned an empty result
    without the leading-comma protection Get-AffinityRuleSet and similar
    loaders use, so it collapsed to $null (and threw on .Count) when no
    overrides were configured for a cluster.
  - Get-HvDRSCapacityForecast's -RemoveNode path could return $null for
    VMPlacements/NodeImpact instead of an empty array when a node has no VMs
    or a cluster has only one remaining node.
  No production behavior changes for callers who already handled populated
  results correctly — these only affected the zero-result / no-rules-configured
  edge cases under strict-mode callers.

## 1.6.0
- Added -TrendWindow / -HistoryPath to Invoke-HvDRS: optional rolling-average
  smoothing of node CPU/network utilization and VM CPU/memory-pressure across
  consecutive passes, so a single transient spike doesn't trigger a migration.
  Disabled by default (-TrendWindow 1) — zero behavior change unless opted in.
- Added Enter-HvDRSNodeMaintenance / Exit-HvDRSNodeMaintenance /
  Get-HvDRSNodeMaintenanceStatus: happiness-aware node evacuation (a Hyper-V
  analog of vSphere's "Enter Maintenance Mode") that live-migrates every VM off
  a node using the same Network-Aware/memory-reserve/affinity-rule destination
  selection as Invoke-HvDRS, then pauses the node — or refuses to pause it if
  any VM couldn't be placed.
- Added VM/Host/CSV Groups (Add/Get/Remove/Set-HvDRSGroup) and new
  -VMGroups/-HostGroups/-CSVGroups parameters on Add/Set-HvDRSAffinityRule:
  reusable named groups that affinity rules can reference instead of listing
  members directly. Group membership resolves dynamically at rule-load time —
  editing a group takes effect immediately, with no rule re-save needed.
- Added per-VM automation-level overrides (Set/Get/Remove-HvDRSVMAutomationLevel):
  pin specific VMs to Manual so Invoke-HvDRS/Invoke-HvStorageDRS keep scoring
  and recommending them but never execute a migration/move for them.
- Added Get-HvDRSCapacityForecast: read-only what-if capacity analysis —
  simulate draining a node (-RemoveNode) to check whether every VM on it has a
  valid destination, or simulate adding a hypothetical node (-AddNode) to see
  which currently-unhappy VMs it could absorb.
- Added -WebhookUrl / -WriteEventLog to Invoke-HvDRS and Invoke-HvStorageDRS:
  optional JSON webhook POST and/or Windows Application event log entry
  summarizing each pass. A notification failure is logged as a warning and
  never fails an otherwise-successful pass.
- Added -PassThru to Invoke-HvStorageDRS (previously compute-only), and
  extended the optional ProPack VMM PRO Tips integration to cover storage DRS
  recommendations (ConvertTo-HvDrsStorageProTip, Resolve-VmmStorageIdentity,
  Invoke-HvDrsStorageProTipProbe, and a parallel monitor/rule pair in the
  Management Pack) — previously compute-only.
- Fixed a latent bug in Invoke-HvStorageDRS where its Format-Table calls were
  never piped to Out-Host, so capturing its return value (now needed by
  -PassThru) leaked PowerShell formatting objects onto the output stream. Same
  class of bug already fixed for Invoke-HvDRS in 1.5.0.
- Moved all documentation except README.md into a new docs/ folder
  (docs/INSTALL.md, docs/USAGE.md, docs/TESTS.md, docs/PUBLISH.md) and added
  docs/ARCHITECTURE.md, a new technical design reference.

## 1.5.1
- Fixed three latent bugs where a zero-match result collapsed to $null instead
  of an empty array/collection at a function or switch-expression output
  boundary: Find-MigrationCandidates (no migrations recommended),
  Get-HvDRSAffinityRule (no rules match a filter), and an internal switch-to-
  variable assignment in the same function. These were silently tolerated by
  PowerShell's default null.Count convenience behavior but threw under
  Set-StrictMode, which the publish pipeline enables — surfaced while
  preparing this release. No behavior change for non-strict-mode callers.

## 1.5.0
- Added -PassThru to Invoke-HvDRS: emits each migration recommendation as a structured
  object (ClusterName, VMName, VMId, SourceNode, DestinationNode, scores, ComplianceReason)
  in addition to the existing console output, for programmatic consumers. Fully additive
  and backward compatible — omitting the switch preserves prior behavior.
- Fixed internal Format-Table calls leaking formatting objects onto the function's output
  stream when callers capture Invoke-HvDRS's return value; they now render to the console
  only via Out-Host.

## 1.4.0
- Added Get-HvDRSCluster: lightweight, read-only discovery of cluster nodes, VMs, and
  Cluster Shared Volumes, with no performance-counter collection and no migrations proposed

## 1.3.0
- CRITICAL FIX: the module manifest was missing RootModule, so Import-Module HVDRS
  never loaded HVDRS.psm1 and exported zero functions in every prior published
  version. RootModule = 'HVDRS.psm1' is now set and the module works correctly.
- Fixed Get-AffinityRuleSet returning $null instead of an empty array on a fresh
  rules store, which broke adding the very first affinity rule
- Added storage-specific affinity/anti-affinity rules: VmVmCsvAffinity, VmVmCsvAntiAffinity,
  VmCsvAffinity, VmCsvAntiAffinity
- Add-HvDRSAffinityRule / Set-HvDRSAffinityRule accept -CSVs (and -AddCSVs/-RemoveCSVs)
- Invoke-HvStorageDRS now loads storage rules, runs a compliance pass ahead of the
  happiness pass, and applies soft-rule penalties / compliance bonuses to candidate scoring
- Added Test-HvDRSStorageAffinityCompliance for live VM-to-CSV placement auditing

## 1.2.1
- Documentation only: promoted PowerShell Gallery install to the recommended option in INSTALL.md
- Updated README Quick Start to use Install-Module instead of Copy-Item

## 1.2.0
- Added per-cluster scoping for affinity/anti-affinity rules
- Rules stored in shared JSON file are now filtered by ClusterName at load time
- Add-HvDRSAffinityRule, Get-HvDRSAffinityRule, Remove-HvDRSAffinityRule all accept -ClusterName
- Same rule name may now exist independently across different clusters

## 1.1.0
- Added Storage DRS (Invoke-HvStorageDRS): CSV space and latency happiness scoring,
  greedy storage migration planner, Move-VMStorage execution
- Added affinity/anti-affinity rules (VmVmAffinity, VmVmAntiAffinity, VmHostAffinity,
  VmHostAntiAffinity) with hard (enforced) and soft enforcement modes
- Added two-pass migration planner: compliance pass fixes hard violations first,
  happiness pass applies rule impact scoring
- Added Test-HvDRSAffinityCompliance for live placement auditing

## 1.0.0
- Initial release: VM Happiness scoring, compute DRS, Network-Aware destination
  filtering, aggression levels 1–5, maintenance mode
'@
        }
    }
}
