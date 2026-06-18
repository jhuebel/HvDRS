@{
    ModuleVersion     = '1.2.0'
    GUID              = 'a3f2c1d4-8e7b-4a9f-b5c6-d2e1f0a3b4c5'
    Author            = 'jhuebel'
    CompanyName       = ''
    Description       = 'Hyper-V Distributed Resource Scheduler — VM Happiness-based compute and storage load balancing for Failover Clusters, with affinity/anti-affinity rule enforcement'
    PowerShellVersion = '5.1'
    RequiredModules   = @('FailoverClusters', 'Hyper-V')
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
    PrivateData       = @{ PSData = @{} }
}
