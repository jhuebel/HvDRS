@{
    RootModule        = 'HVDRS.psm1'
    ModuleVersion     = '1.3.0'
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
        'Enable-HvDRSMaintenance',
        'Disable-HvDRSMaintenance',
        'Get-HvDRSMaintenanceStatus',
        'Add-HvDRSAffinityRule',
        'Get-HvDRSAffinityRule',
        'Remove-HvDRSAffinityRule',
        'Set-HvDRSAffinityRule',
        'Test-HvDRSAffinityCompliance',
        'Test-HvDRSStorageAffinityCompliance',
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
