@{
    ModuleVersion     = '1.2.1'
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
