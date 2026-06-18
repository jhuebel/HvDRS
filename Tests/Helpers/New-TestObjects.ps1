# Shared builders for HVDRS unit tests.
# Dot-source this file inside BeforeAll blocks.

function New-HostMetrics {
    param(
        [string][Parameter(Mandatory)] $Name,
        [float]  $CpuUtil    = 50.0,
        [int]    $TotalMemMB = 131072,   # 128 GB
        [int]    $AvailMemMB = 65536,    # 50 % used
        [int]    $LPs        = 32,
        [float]  $NetUtil    = 10.0
    )
    [PSCustomObject]@{
        NodeName              = $Name
        CpuUtilization        = $CpuUtil
        TotalMemoryMB         = $TotalMemMB
        AvailableMemoryMB     = $AvailMemMB
        UsedMemoryMB          = $TotalMemMB - $AvailMemMB
        LogicalProcessorCount = $LPs
        NetworkUtilization    = $NetUtil
        VMs                   = @()
    }
}

function New-VmMetrics {
    param(
        [string][Parameter(Mandatory)] $Name,
        [string] $HostNode    = 'NODE1',
        [float]  $CpuUtil     = 30.0,
        [int]    $Procs       = 4,
        [int]    $MemAssignMB = 8192,
        [bool]   $DynMem      = $true,
        [float]  $Pressure    = 100.0
    )
    [PSCustomObject]@{
        VMName               = $Name
        VMId                 = [System.Guid]::NewGuid().ToString()
        CpuUtilization       = $CpuUtil
        ProcessorCount       = $Procs
        MemoryAssignedMB     = $MemAssignMB
        MemoryDemandMB       = $MemAssignMB
        DynamicMemoryEnabled = $DynMem
        MemoryPressure       = $Pressure
        HostNode             = $HostNode
    }
}

function New-Snapshot {
    param(
        [string]           $ClusterName = 'TEST-CLUSTER',
        [PSCustomObject[]] $Nodes,
        [PSCustomObject[]] $VMs
    )
    [PSCustomObject]@{
        ClusterName = $ClusterName
        Timestamp   = Get-Date
        Nodes       = $Nodes
        VMs         = $VMs
    }
}
