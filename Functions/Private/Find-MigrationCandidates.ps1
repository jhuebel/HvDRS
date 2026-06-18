function Find-MigrationCandidates {
    <#
    .SYNOPSIS
        Identifies VMs that would benefit from Live Migration and selects optimal destination nodes.

    .DESCRIPTION
        Algorithm:
          1. Score every running VM using Measure-VmHappiness.
          2. Sort by score ascending (most miserable first).
          3. For each VM below the aggression-level happiness threshold:
             a. Retrieve cluster possible-owners (respects affinity rules).
             b. Exclude network-saturated destinations (Network-Aware DRS).
             c. Exclude destinations with insufficient free memory.
             d. Simulate post-migration happiness on each candidate.
             e. If the best improvement exceeds the aggression-level improvement threshold, add
                the migration to the plan and update the simulated cluster state so subsequent
                decisions account for already-planned moves.

    .OUTPUTS
        List of PSCustomObjects describing each recommended migration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3,

        [float]$CpuWeight    = 0.5,
        [float]$MemoryWeight = 0.5,

        # Destination hosts with network utilization above this % are excluded.
        [float]$MaxDestinationNetworkUtil = 70.0,

        # Minimum free memory (MB) that must remain on the destination after migration.
        [int]$DestinationMemoryReserveMB = 512,

        [Parameter(Mandatory)]
        [string]$ClusterName
    )

    # Aggression level → [happiness threshold, minimum improvement to trigger migration]
    $thresholds = @{
        1 = @{ Happiness = 30; Improvement = 40 }
        2 = @{ Happiness = 40; Improvement = 30 }
        3 = @{ Happiness = 50; Improvement = 20 }
        4 = @{ Happiness = 60; Improvement = 15 }
        5 = @{ Happiness = 70; Improvement = 10 }
    }
    $happinessThreshold   = $thresholds[$AggressionLevel].Happiness
    $improvementThreshold = $thresholds[$AggressionLevel].Improvement

    # Score all running VMs
    $vmScores = foreach ($vm in $Snapshot.VMs) {
        $host = $Snapshot.Nodes | Where-Object { $_.NodeName -eq $vm.HostNode }
        if (-not $host) { continue }
        Measure-VmHappiness -VmMetrics $vm -HostMetrics $host `
                            -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
    }

    # Mutable simulated node state — updated as migrations are planned so that
    # later decisions in the same pass account for already-queued moves.
    $simNodes = @{}
    foreach ($node in $Snapshot.Nodes) {
        $simNodes[$node.NodeName] = [PSCustomObject]@{
            NodeName              = $node.NodeName
            CpuUtilization        = $node.CpuUtilization
            TotalMemoryMB         = $node.TotalMemoryMB
            AvailableMemoryMB     = $node.AvailableMemoryMB
            LogicalProcessorCount = $node.LogicalProcessorCount
            NetworkUtilization    = $node.NetworkUtilization
        }
    }

    $scheduledVMs = [System.Collections.Generic.HashSet[string]]::new()
    $migrations   = [System.Collections.Generic.List[PSCustomObject]]::new()

    $unhappyVMs = $vmScores |
                  Where-Object { $_.HappinessScore -lt $happinessThreshold } |
                  Sort-Object HappinessScore   # most unhappy first

    foreach ($score in $unhappyVMs) {
        if ($scheduledVMs.Contains($score.VMName)) { continue }

        $vm = $Snapshot.VMs | Where-Object { $_.VMName -eq $score.VMName }
        if (-not $vm) { continue }

        # ── Cluster ownership constraints ──────────────────────────────────────
        $possibleOwners = try {
            (Get-ClusterOwnerNode -Cluster $ClusterName `
                                  -Group "Virtual Machine $($vm.VMName)" `
                                  -ErrorAction Stop).OwnerNodes.Name
        } catch {
            # Group not found or no constraints — allow all nodes
            $Snapshot.Nodes | Select-Object -ExpandProperty NodeName
        }

        # ── Filter destination candidates ──────────────────────────────────────
        $candidates = $simNodes.Values | Where-Object {
            $_.NodeName -ne $score.HostNode -and
            ($possibleOwners -contains $_.NodeName) -and
            $_.NetworkUtilization -lt $MaxDestinationNetworkUtil -and
            ($_.AvailableMemoryMB - $vm.MemoryAssignedMB) -ge $DestinationMemoryReserveMB
        }

        if (-not $candidates) {
            Write-Verbose "  No eligible destination for '$($vm.VMName)' (network-saturated or insufficient memory on all candidates)."
            continue
        }

        # ── Simulate placement on each candidate; pick the best improvement ────
        $bestMigration  = $null
        $bestImprovement = 0.0

        foreach ($candidate in $candidates) {
            # CPU impact of the VM on the destination host
            $cpuImpact = ($vm.CpuUtilization / 100.0) *
                         ($vm.ProcessorCount / $candidate.LogicalProcessorCount) * 100.0

            $simHostMetrics = [PSCustomObject]@{
                NodeName              = $candidate.NodeName
                CpuUtilization        = [Math]::Min(100.0, $candidate.CpuUtilization + $cpuImpact)
                TotalMemoryMB         = $candidate.TotalMemoryMB
                AvailableMemoryMB     = $candidate.AvailableMemoryMB - $vm.MemoryAssignedMB
                LogicalProcessorCount = $candidate.LogicalProcessorCount
                NetworkUtilization    = $candidate.NetworkUtilization
            }

            # For Dynamic Memory VMs: if the destination has ample headroom, assume
            # pressure will normalise back to 100 (balanced) after migration.
            $simMemPressure = $vm.MemoryPressure
            if ($vm.DynamicMemoryEnabled -and
                $candidate.AvailableMemoryMB -gt ($vm.MemoryAssignedMB * 1.5)) {
                $simMemPressure = [Math]::Min($vm.MemoryPressure, 100.0)
            }

            $simVmMetrics = [PSCustomObject]@{
                VMName               = $vm.VMName
                HostNode             = $candidate.NodeName
                CpuUtilization       = $vm.CpuUtilization
                ProcessorCount       = $vm.ProcessorCount
                MemoryAssignedMB     = $vm.MemoryAssignedMB
                MemoryDemandMB       = $vm.MemoryDemandMB
                DynamicMemoryEnabled = $vm.DynamicMemoryEnabled
                MemoryPressure       = $simMemPressure
            }

            $projected   = Measure-VmHappiness -VmMetrics $simVmMetrics -HostMetrics $simHostMetrics `
                                               -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
            $improvement = $projected.HappinessScore - $score.HappinessScore

            if ($improvement -gt $bestImprovement) {
                $bestImprovement = $improvement
                $bestMigration = [PSCustomObject]@{
                    VMName             = $vm.VMName
                    VMId               = $vm.VMId
                    SourceNode         = $score.HostNode
                    DestinationNode    = $candidate.NodeName
                    CurrentScore       = $score.HappinessScore
                    ProjectedScore     = [Math]::Round($projected.HappinessScore, 1)
                    Improvement        = [Math]::Round($improvement, 1)
                    CpuHappinessBefore = $score.CpuHappiness
                    MemHappinessBefore = $score.MemHappiness
                    CpuHappinessAfter  = [Math]::Round($projected.CpuHappiness, 1)
                    MemHappinessAfter  = [Math]::Round($projected.MemHappiness, 1)
                }
            }
        }

        if ($null -eq $bestMigration -or $bestImprovement -lt $improvementThreshold) { continue }

        $migrations.Add($bestMigration)
        [void]$scheduledVMs.Add($bestMigration.VMName)

        # ── Update simulated state so subsequent iterations stay consistent ────
        $src = $simNodes[$bestMigration.SourceNode]
        $dst = $simNodes[$bestMigration.DestinationNode]

        $srcCpuRelief = ($vm.CpuUtilization / 100.0) *
                        ($vm.ProcessorCount / $src.LogicalProcessorCount) * 100.0
        $dstCpuLoad   = ($vm.CpuUtilization / 100.0) *
                        ($vm.ProcessorCount / $dst.LogicalProcessorCount) * 100.0

        $src.CpuUtilization    = [Math]::Max(0.0,   $src.CpuUtilization   - $srcCpuRelief)
        $src.AvailableMemoryMB = $src.AvailableMemoryMB + $vm.MemoryAssignedMB
        $dst.CpuUtilization    = [Math]::Min(100.0, $dst.CpuUtilization   + $dstCpuLoad)
        $dst.AvailableMemoryMB = $dst.AvailableMemoryMB - $vm.MemoryAssignedMB
    }

    return $migrations
}
