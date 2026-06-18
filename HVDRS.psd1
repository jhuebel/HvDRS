@{
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f2c1d4-8e7b-4a9f-b5c6-d2e1f0a3b4c5'
    Author            = 'jhuebel'
    CompanyName       = ''
    Description       = 'Hyper-V Distributed Resource Scheduler — VM Happiness-based load balancing for Failover Clusters'
    PowerShellVersion = '5.1'
    RequiredModules   = @('FailoverClusters', 'Hyper-V')
    FunctionsToExport = @(
        'Invoke-HvDRS',
        'Enable-HvDRSMaintenance',
        'Disable-HvDRSMaintenance',
        'Get-HvDRSMaintenanceStatus'
    )
    PrivateData       = @{ PSData = @{} }
}
