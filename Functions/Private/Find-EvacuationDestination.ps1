function Find-EvacuationDestination {
    <#
    .SYNOPSIS
        Chooses the best destination node for a single VM that must move off a
        specific node (e.g. entering maintenance), regardless of any happiness
        improvement threshold — a destination is required, not merely preferred.

    .DESCRIPTION
        Applies the same destination-filtering rules Find-MigrationCandidates uses
        (possible-owner constraints, the Network-Aware NIC utilization gate, the
        post-migration memory reserve, and hard/soft affinity-rule impact via
        Get-MigrationRuleImpact) but with no minimum-improvement gate, since the VM
        must be placed somewhere rather than only when it would help.

        Side effect: when a destination is found, this function updates the chosen
        destination node's simulated CpuUtilization/AvailableMemoryMB in place on
        -Snapshot.Nodes, and sets -VM.HostNode to the chosen destination. This lets
        a caller evacuating multiple VMs off the same node call this repeatedly in
        a loop without a second VM landing on a destination the first VM's move has
        already filled — the same greedy state-update pattern Find-MigrationCandidates
        applies after each planned migration. No state is mutated when no valid
        destination is found.

    .OUTPUTS
        PSCustomObject (VMName, VMId, SourceNode, DestinationNode, ProjectedScore,
        CpuHappinessAfter, MemHappinessAfter) if a destination is found; $null if no
        candidate satisfies every constraint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VM,

        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot,

        [Parameter(Mandatory)]
        [string]$ExcludeNode,

        [PSCustomObject[]]$RuleSet = @(),

        [float]$CpuWeight    = 0.5,
        [float]$MemoryWeight = 0.5,

        [float]$MaxDestinationNetworkUtil   = 70.0,
        [int]  $DestinationMemoryReserveMB = 512,

        [float]$SoftRuleViolationPenalty = 25.0,
        [float]$RuleComplianceBonus      = 25.0,

        [Parameter(Mandatory)]
        [string]$ClusterName
    )

    $possibleOwners = try {
        (Get-ClusterOwnerNode -Cluster $ClusterName -Group "Virtual Machine $($VM.VMName)" -ErrorAction Stop).OwnerNodes.Name
    } catch {
        $Snapshot.Nodes | Select-Object -ExpandProperty NodeName
    }

    $candidates = $Snapshot.Nodes | Where-Object {
        $_.NodeName -ne $ExcludeNode -and
        ($possibleOwners -contains $_.NodeName) -and
        $_.NetworkUtilization -lt $MaxDestinationNetworkUtil -and
        ($_.AvailableMemoryMB - $VM.MemoryAssignedMB) -ge $DestinationMemoryReserveMB
    }

    $best      = $null
    $bestScore = -1

    foreach ($candidate in $candidates) {
        $impact = if ($RuleSet -and $RuleSet.Count -gt 0) {
            Get-MigrationRuleImpact -VMName $VM.VMName -DestinationNode $candidate.NodeName `
                                    -Snapshot $Snapshot -RuleSet $RuleSet
        } else {
            [PSCustomObject]@{ HasHardViolation = $false; HasSoftViolation = $false; FixesViolation = $false }
        }

        if ($impact.HasHardViolation) { continue }

        $cpuImpact = ($VM.CpuUtilization / 100.0) * ($VM.ProcessorCount / $candidate.LogicalProcessorCount) * 100.0
        $simHost = [PSCustomObject]@{
            NodeName              = $candidate.NodeName
            CpuUtilization        = [Math]::Min(100.0, $candidate.CpuUtilization + $cpuImpact)
            TotalMemoryMB         = $candidate.TotalMemoryMB
            AvailableMemoryMB     = $candidate.AvailableMemoryMB - $VM.MemoryAssignedMB
            LogicalProcessorCount = $candidate.LogicalProcessorCount
            NetworkUtilization    = $candidate.NetworkUtilization
        }

        $simPressure = $VM.MemoryPressure
        if ($VM.DynamicMemoryEnabled -and $candidate.AvailableMemoryMB -gt ($VM.MemoryAssignedMB * 1.5)) {
            $simPressure = [Math]::Min($VM.MemoryPressure, 100.0)
        }

        $simVm = [PSCustomObject]@{
            VMName               = $VM.VMName
            HostNode             = $candidate.NodeName
            CpuUtilization       = $VM.CpuUtilization
            ProcessorCount       = $VM.ProcessorCount
            MemoryAssignedMB     = $VM.MemoryAssignedMB
            MemoryDemandMB       = $VM.MemoryDemandMB
            DynamicMemoryEnabled = $VM.DynamicMemoryEnabled
            MemoryPressure       = $simPressure
        }

        $projected = Measure-VmHappiness -VmMetrics $simVm -HostMetrics $simHost `
                                         -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight

        $adjustedScore = $projected.HappinessScore
        if ($impact.HasSoftViolation) { $adjustedScore = [Math]::Max(0,   $adjustedScore - $SoftRuleViolationPenalty) }
        if ($impact.FixesViolation)   { $adjustedScore = [Math]::Min(100, $adjustedScore + $RuleComplianceBonus) }

        if ($adjustedScore -gt $bestScore) {
            $bestScore = $adjustedScore
            $best = [PSCustomObject]@{
                VMName            = $VM.VMName
                VMId              = $VM.VMId
                SourceNode        = $ExcludeNode
                DestinationNode   = $candidate.NodeName
                ProjectedScore    = [Math]::Round($projected.HappinessScore, 1)
                CpuHappinessAfter = [Math]::Round($projected.CpuHappiness, 1)
                MemHappinessAfter = [Math]::Round($projected.MemHappiness, 1)
            }
        }
    }

    if (-not $best) { return $null }

    # Greedy state update — see the Side effect note above.
    $destNode = $Snapshot.Nodes | Where-Object { $_.NodeName -eq $best.DestinationNode }
    if ($destNode) {
        $cpuImpact = ($VM.CpuUtilization / 100.0) * ($VM.ProcessorCount / $destNode.LogicalProcessorCount) * 100.0
        $destNode.CpuUtilization    = [Math]::Min(100.0, $destNode.CpuUtilization + $cpuImpact)
        $destNode.AvailableMemoryMB = $destNode.AvailableMemoryMB - $VM.MemoryAssignedMB
    }
    $VM.HostNode = $best.DestinationNode

    return $best
}
