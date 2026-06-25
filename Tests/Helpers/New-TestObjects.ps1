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

# ── Storage DRS helpers ────────────────────────────────────────────────────────

function New-CsvMetrics {
    param(
        [string] $Name      = 'Volume1',
        [string] $Path      = 'C:\ClusterStorage\Volume1',
        [string] $OwnerNode = 'NODE1',
        [float]  $TotalGB   = 2048.0,
        [float]  $FreeGB    = 1024.0,
        [object] $LatencyMs = $null,   # nullable; $null = I/O data not available
        [object] $ReadIOPS  = $null,
        [object] $WriteIOPS = $null
    )
    $usedGB = $TotalGB - $FreeGB
    [PSCustomObject]@{
        Name         = $Name
        Path         = $Path
        OwnerNode    = $OwnerNode
        TotalGB      = $TotalGB
        FreeGB       = $FreeGB
        UsedGB       = $usedGB
        SpaceUsedPct = if ($TotalGB -gt 0) { [Math]::Round(($usedGB / $TotalGB) * 100.0, 1) } else { 0.0 }
        LatencyMs    = $LatencyMs
        ReadIOPS     = $ReadIOPS
        WriteIOPS    = $WriteIOPS
    }
}

function New-VmStorageMetrics {
    param(
        [string] $Name       = 'VM1',
        [string] $HostNode   = 'NODE1',
        [string] $PrimaryCSV = 'C:\ClusterStorage\Volume1',
        [float]  $TotalVhdGB = 50.0
    )
    [PSCustomObject]@{
        VMName     = $Name
        VMId       = [System.Guid]::NewGuid().ToString()
        HostNode   = $HostNode
        PrimaryCSV = $PrimaryCSV
        TotalVhdGB = $TotalVhdGB
        VHDs       = @([PSCustomObject]@{
            Path   = "$PrimaryCSV\VMs\$Name\$Name.vhdx"
            SizeGB = $TotalVhdGB
            CSV    = $PrimaryCSV
        })
    }
}

# ── ProPack helpers ────────────────────────────────────────────────────────────

function New-MigrationRecommendation {
    param(
        [string] $ClusterName     = 'TEST-CLUSTER',
        [object] $GeneratedAt     = (Get-Date),
        [string] $VMName          = 'VM1',
        [string] $VMId            = [System.Guid]::NewGuid().ToString(),
        [string] $SourceNode      = 'NODE1',
        [string] $DestinationNode = 'NODE2',
        [float]  $CurrentScore        = 20.0,
        [float]  $ProjectedScore      = 80.0,
        [float]  $Improvement         = 60.0,
        [float]  $CpuHappinessBefore  = 0.0,
        [float]  $MemHappinessBefore  = 40.0,
        [float]  $CpuHappinessAfter   = 100.0,
        [float]  $MemHappinessAfter   = 100.0,
        [object] $ComplianceReason    = $null
    )
    [PSCustomObject]@{
        ClusterName        = $ClusterName
        GeneratedAt        = $GeneratedAt
        VMName             = $VMName
        VMId               = $VMId
        SourceNode         = $SourceNode
        DestinationNode    = $DestinationNode
        CurrentScore       = $CurrentScore
        ProjectedScore     = $ProjectedScore
        Improvement        = $Improvement
        CpuHappinessBefore = $CpuHappinessBefore
        MemHappinessBefore = $MemHappinessBefore
        CpuHappinessAfter  = $CpuHappinessAfter
        MemHappinessAfter  = $MemHappinessAfter
        ComplianceReason   = $ComplianceReason
    }
}

function New-StorageSnapshot {
    param(
        [string]           $ClusterName = 'TEST-CLUSTER',
        [PSCustomObject[]] $CSVs,
        [PSCustomObject[]] $VMs
    )
    [PSCustomObject]@{
        ClusterName = $ClusterName
        Timestamp   = Get-Date
        CSVs        = $CSVs
        VMs         = $VMs
    }
}
