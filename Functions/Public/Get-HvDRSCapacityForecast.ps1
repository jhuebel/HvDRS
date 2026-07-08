function Get-HvDRSCapacityForecast {
    <#
    .SYNOPSIS
        Simulates removing or adding a cluster node and reports the projected VM
        happiness impact — a read-only, vSphere-DRS-style "what-if" capacity
        analysis. Never migrates or moves anything.

    .DESCRIPTION
        Two mutually exclusive scenarios:

        -RemoveNode <NodeName>
          Simulates draining that node right now: every VM currently on it is run
          through the same destination-selection logic Enter-HvDRSNodeMaintenance
          uses (Find-EvacuationDestination — Network-Aware gate, memory reserve,
          possible-owner constraints, hard/soft affinity-rule impact) to project
          where it would land. Reports each VM's current vs. projected happiness,
          flags any VM with no valid destination, and reports before/after
          utilization for every remaining node. Nothing on the real cluster is
          touched or queried for possible-owner data beyond the initial snapshot.

        -AddNode <NodeName> -AddNodeCpuCores <int> -AddNodeMemoryMB <int>
          Injects a synthetic idle node with the given specs into the snapshot and
          checks which of the cluster's currently-unhappy VMs (below the
          aggression-level threshold) could be absorbed by it and by how much their
          happiness would improve. This intentionally does NOT go through
          Find-MigrationCandidates' possible-owner check — a node that doesn't
          exist yet in the real cluster has no possible-owner membership to query,
          and the entire point of this scenario is to answer "would adding this
          node help" independent of the cluster-group configuration you'd still
          need to set up afterward.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER RemoveNode
        Simulate draining and removing this node. Mutually exclusive with -AddNode.

    .PARAMETER AddNode
        Name for a hypothetical new node (does not need to exist in the real
        cluster). Mutually exclusive with -RemoveNode.

    .PARAMETER AddNodeCpuCores
        Logical processor count for the hypothetical node (default: 32).

    .PARAMETER AddNodeMemoryMB
        Total/available memory (MB) for the hypothetical node, assumed fully idle
        (default: 131072 MB / 128 GB).

    .PARAMETER AddNodeNetworkUtil
        Assumed NIC utilization percentage for the hypothetical node (default: 0 — idle).

    .PARAMETER AggressionLevel
        Same happiness-threshold/minimum-improvement table as Invoke-HvDRS (default: 3).

    .PARAMETER CpuWeight / MemoryWeight / MaxDestinationNetworkUtil / DestinationMemoryReserveMB
        Same meaning and defaults as the identically-named Invoke-HvDRS parameters.

    .PARAMETER RulesPath
        Path to the JSON affinity rule store. Same default as Invoke-HvDRS.

    .PARAMETER SoftRuleViolationPenalty / RuleComplianceBonus
        Same meaning and defaults as the identically-named Invoke-HvDRS parameters.

    .PARAMETER SampleCount / SampleIntervalSeconds
        Passed through to Get-ClusterSnapshot (defaults: 5 samples / 2s interval).

    .EXAMPLE
        # Can we safely take HV-NODE3 down for hardware maintenance?
        Get-HvDRSCapacityForecast -ClusterName 'PROD-CLUSTER' -RemoveNode 'HV-NODE3'

    .EXAMPLE
        # Would a new 64-core / 256GB node meaningfully help the cluster?
        Get-HvDRSCapacityForecast -ClusterName 'PROD-CLUSTER' -AddNode 'HV-NODE9' -AddNodeCpuCores 64 -AddNodeMemoryMB 262144
    #>
    [CmdletBinding(DefaultParameterSetName = 'RemoveNode')]
    param(
        [string]$ClusterName,

        [Parameter(ParameterSetName = 'RemoveNode', Mandatory)]
        [string]$RemoveNode,

        [Parameter(ParameterSetName = 'AddNode', Mandatory)]
        [string]$AddNode,

        [Parameter(ParameterSetName = 'AddNode')]
        [int]$AddNodeCpuCores = 32,

        [Parameter(ParameterSetName = 'AddNode')]
        [int]$AddNodeMemoryMB = 131072,

        [Parameter(ParameterSetName = 'AddNode')]
        [ValidateRange(0.0, 100.0)]
        [float]$AddNodeNetworkUtil = 0.0,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3,

        [ValidateRange(0.0, 1.0)]
        [float]$CpuWeight = 0.5,

        [ValidateRange(0.0, 1.0)]
        [float]$MemoryWeight = 0.5,

        [ValidateRange(0.0, 100.0)]
        [float]$MaxDestinationNetworkUtil = 70.0,

        [int]$DestinationMemoryReserveMB = 512,

        [string]$RulesPath = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json'),

        [ValidateRange(0.0, 100.0)]
        [float]$SoftRuleViolationPenalty = 25.0,

        [ValidateRange(0.0, 100.0)]
        [float]$RuleComplianceBonus = 25.0,

        [int]$SampleCount = 5,

        [int]$SampleIntervalSeconds = 2
    )

    # Same aggression-level table as Find-MigrationCandidates/Find-StorageMigrationCandidates
    # — duplicated rather than shared, matching how those two already duplicate it.
    $thresholds = @{
        1 = @{ Happiness = 30; Improvement = 40 }
        2 = @{ Happiness = 40; Improvement = 30 }
        3 = @{ Happiness = 50; Improvement = 20 }
        4 = @{ Happiness = 60; Improvement = 15 }
        5 = @{ Happiness = 70; Improvement = 10 }
    }
    $happinessThreshold   = $thresholds[$AggressionLevel].Happiness
    $improvementThreshold = $thresholds[$AggressionLevel].Improvement

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    Write-Host "Collecting cluster snapshot..."
    $snapshot = Get-ClusterSnapshot -ClusterName $ClusterName -SampleCount $SampleCount -SampleIntervalSeconds $SampleIntervalSeconds
    $ruleSet  = Get-AffinityRuleSet -Path $RulesPath -ClusterName $ClusterName

    if ($PSCmdlet.ParameterSetName -eq 'RemoveNode') {

        if (-not ($snapshot.Nodes | Where-Object { $_.NodeName -eq $RemoveNode })) {
            throw "Node '$RemoveNode' was not found in cluster '$ClusterName'."
        }

        # Snapshot pre-simulation node state before Find-EvacuationDestination
        # mutates destination nodes in place.
        $nodesBefore = @{}
        foreach ($node in $snapshot.Nodes) {
            $nodesBefore[$node.NodeName] = [PSCustomObject]@{
                CpuUtilization    = $node.CpuUtilization
                AvailableMemoryMB = $node.AvailableMemoryMB
            }
        }

        $vmsOnNode = @($snapshot.VMs | Where-Object { $_.HostNode -eq $RemoveNode })

        Write-Host "Simulating removal of '$RemoveNode' ($($vmsOnNode.Count) VM(s) to place)..."

        $placements = foreach ($vm in $vmsOnNode) {
            $hostMetrics  = $snapshot.Nodes | Where-Object { $_.NodeName -eq $vm.HostNode }
            $currentScore = (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics `
                                                 -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight).HappinessScore

            $dest = Find-EvacuationDestination -VM $vm -Snapshot $snapshot -ExcludeNode $RemoveNode `
                                               -RuleSet $ruleSet -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight `
                                               -MaxDestinationNetworkUtil $MaxDestinationNetworkUtil `
                                               -DestinationMemoryReserveMB $DestinationMemoryReserveMB `
                                               -SoftRuleViolationPenalty $SoftRuleViolationPenalty `
                                               -RuleComplianceBonus $RuleComplianceBonus `
                                               -ClusterName $ClusterName

            [PSCustomObject]@{
                VMName         = $vm.VMName
                CurrentNode    = $RemoveNode
                CurrentScore   = [Math]::Round($currentScore, 1)
                ProjectedNode  = if ($dest) { $dest.DestinationNode } else { $null }
                ProjectedScore = if ($dest) { $dest.ProjectedScore } else { $null }
                Placed         = [bool]$dest
            }
        }

        $unplaced = @($placements | Where-Object { -not $_.Placed })
        $feasible = $unplaced.Count -eq 0

        $nodeImpact = foreach ($node in $snapshot.Nodes) {
            if ($node.NodeName -eq $RemoveNode) { continue }
            $before = $nodesBefore[$node.NodeName]
            [PSCustomObject]@{
                NodeName        = $node.NodeName
                CpuBefore       = $before.CpuUtilization
                CpuAfter        = [Math]::Round($node.CpuUtilization, 1)
                FreeMemBeforeMB = $before.AvailableMemoryMB
                FreeMemAfterMB  = [Math]::Round($node.AvailableMemoryMB, 0)
            }
        }

        Write-Host ''
        if ($vmsOnNode.Count -eq 0) {
            Write-Host "No running VMs on '$RemoveNode' — removal is trivially feasible."
        } elseif ($feasible) {
            Write-Host "All $($vmsOnNode.Count) VM(s) on '$RemoveNode' can be placed elsewhere. Removal is FEASIBLE."
        } else {
            Write-Host "$($unplaced.Count) of $($vmsOnNode.Count) VM(s) on '$RemoveNode' have NO valid destination. Removal is NOT feasible as-is." -ForegroundColor Yellow
        }

        if ($placements) {
            Write-Host ''
            Write-Host '── VM Placement Forecast ─────────────────────────────────────────────────────'
            $placements | Format-Table -AutoSize -Property `
                @{ N='VM';        E={ $_.VMName } },
                @{ N='From';      E={ $_.CurrentNode } },
                @{ N='Score';     E={ $_.CurrentScore } },
                @{ N='To';        E={ if ($_.ProjectedNode) { $_.ProjectedNode } else { 'NONE' } } },
                @{ N='New Score'; E={ $_.ProjectedScore } },
                @{ N='Placed';    E={ $_.Placed } } | Out-Host
        }

        Write-Host '── Node Utilization Impact ───────────────────────────────────────────────────'
        $nodeImpact | Format-Table -AutoSize -Property `
            @{ N='Node';        E={ $_.NodeName } },
            @{ N='CPU Before';  E={ '{0:N1}%' -f $_.CpuBefore } },
            @{ N='CPU After';   E={ '{0:N1}%' -f $_.CpuAfter } },
            @{ N='Free Mem Before'; E={ '{0:N0} MB' -f $_.FreeMemBeforeMB } },
            @{ N='Free Mem After';  E={ '{0:N0} MB' -f $_.FreeMemAfterMB } } | Out-Host

        return [PSCustomObject]@{
            ClusterName  = $ClusterName
            Scenario     = 'RemoveNode'
            TargetNode   = $RemoveNode
            Feasible     = $feasible
            # @()-wrapped: a foreach-as-expression with zero iterations (e.g. no
            # VMs on the node, or a single-node cluster) yields $null rather than
            # an empty array, which would otherwise make .Count throw under
            # Set-StrictMode for a caller that doesn't already know to check.
            VMPlacements = @($placements)
            NodeImpact   = @($nodeImpact)
        }
    }

    # ── AddNode scenario ───────────────────────────────────────────────────────
    if ($snapshot.Nodes | Where-Object { $_.NodeName -eq $AddNode }) {
        throw "A node named '$AddNode' already exists in cluster '$ClusterName' — choose a different hypothetical name."
    }

    $syntheticNode = [PSCustomObject]@{
        NodeName              = $AddNode
        CpuUtilization        = 0.0
        TotalMemoryMB          = $AddNodeMemoryMB
        AvailableMemoryMB     = $AddNodeMemoryMB
        UsedMemoryMB          = 0
        LogicalProcessorCount = $AddNodeCpuCores
        NetworkUtilization    = $AddNodeNetworkUtil
        VMs                   = @()
    }

    Write-Host "Simulating addition of '$AddNode' ($AddNodeCpuCores logical processors, $AddNodeMemoryMB MB memory)..."

    if ($syntheticNode.NetworkUtilization -ge $MaxDestinationNetworkUtil) {
        Write-Warning "Hypothetical node's -AddNodeNetworkUtil ($($syntheticNode.NetworkUtilization)%) is at or above -MaxDestinationNetworkUtil ($MaxDestinationNetworkUtil%) — it would never qualify as a migration target."
    }

    $vmScores = foreach ($vm in $snapshot.VMs) {
        $hostMetrics = $snapshot.Nodes | Where-Object { $_.NodeName -eq $vm.HostNode }
        if (-not $hostMetrics) { continue }
        Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
    }

    $unhappyVMs = $vmScores | Where-Object { $_.HappinessScore -lt $happinessThreshold } | Sort-Object HappinessScore
    $absorbed   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($score in $unhappyVMs) {
        $vm = $snapshot.VMs | Where-Object { $_.VMName -eq $score.VMName }
        if (-not $vm) { continue }

        if ($syntheticNode.NetworkUtilization -ge $MaxDestinationNetworkUtil) { continue }
        if (($syntheticNode.AvailableMemoryMB - $vm.MemoryAssignedMB) -lt $DestinationMemoryReserveMB) { continue }

        $impact = if ($ruleSet -and $ruleSet.Count -gt 0) {
            Get-MigrationRuleImpact -VMName $vm.VMName -DestinationNode $AddNode -Snapshot $snapshot -RuleSet $ruleSet
        } else {
            [PSCustomObject]@{ HasHardViolation = $false; HasSoftViolation = $false; FixesViolation = $false }
        }
        if ($impact.HasHardViolation) { continue }

        $cpuImpact = ($vm.CpuUtilization / 100.0) * ($vm.ProcessorCount / $syntheticNode.LogicalProcessorCount) * 100.0
        $simHost = [PSCustomObject]@{
            NodeName              = $syntheticNode.NodeName
            CpuUtilization        = [Math]::Min(100.0, $syntheticNode.CpuUtilization + $cpuImpact)
            TotalMemoryMB         = $syntheticNode.TotalMemoryMB
            AvailableMemoryMB     = $syntheticNode.AvailableMemoryMB - $vm.MemoryAssignedMB
            LogicalProcessorCount = $syntheticNode.LogicalProcessorCount
            NetworkUtilization    = $syntheticNode.NetworkUtilization
        }
        $simVm = [PSCustomObject]@{
            VMName               = $vm.VMName
            HostNode             = $syntheticNode.NodeName
            CpuUtilization       = $vm.CpuUtilization
            ProcessorCount       = $vm.ProcessorCount
            MemoryAssignedMB     = $vm.MemoryAssignedMB
            MemoryDemandMB       = $vm.MemoryDemandMB
            DynamicMemoryEnabled = $vm.DynamicMemoryEnabled
            MemoryPressure       = $vm.MemoryPressure
        }
        $projected = Measure-VmHappiness -VmMetrics $simVm -HostMetrics $simHost -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight

        $adjustedScore = $projected.HappinessScore
        if ($impact.HasSoftViolation) { $adjustedScore = [Math]::Max(0,   $adjustedScore - $SoftRuleViolationPenalty) }
        if ($impact.FixesViolation)   { $adjustedScore = [Math]::Min(100, $adjustedScore + $RuleComplianceBonus) }

        $improvement = $adjustedScore - $score.HappinessScore
        if ($improvement -lt $improvementThreshold) { continue }

        $absorbed.Add([PSCustomObject]@{
            VMName          = $vm.VMName
            CurrentNode     = $vm.HostNode
            CurrentScore    = $score.HappinessScore
            ProjectedScore  = [Math]::Round($projected.HappinessScore, 1)
            Improvement     = [Math]::Round($improvement, 1)
        })

        # Greedy state update on the synthetic node before evaluating the next VM
        $syntheticNode.CpuUtilization    = $simHost.CpuUtilization
        $syntheticNode.AvailableMemoryMB = $simHost.AvailableMemoryMB
    }

    Write-Host ''
    if ($absorbed.Count -eq 0) {
        Write-Host "Adding '$AddNode' would not meaningfully improve any currently-unhappy VM at aggression level $AggressionLevel."
    } else {
        Write-Host "Adding '$AddNode' could absorb $($absorbed.Count) currently-unhappy VM(s):"
        Write-Host ''
        $absorbed | Format-Table -AutoSize -Property `
            @{ N='VM';           E={ $_.VMName } },
            @{ N='Current Node'; E={ $_.CurrentNode } },
            @{ N='Score Before'; E={ $_.CurrentScore } },
            @{ N='Score After';  E={ $_.ProjectedScore } },
            @{ N='Delta';        E={ '+{0}' -f $_.Improvement } } | Out-Host
    }

    return [PSCustomObject]@{
        ClusterName          = $ClusterName
        Scenario             = 'AddNode'
        TargetNode           = $AddNode
        AbsorbedRecommendations = $absorbed.ToArray()
    }
}
