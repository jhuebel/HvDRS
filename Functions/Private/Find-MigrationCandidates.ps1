function Find-MigrationCandidates {
    <#
    .SYNOPSIS
        Identifies VMs that would benefit from Live Migration and selects optimal destination nodes,
        now with full affinity / anti-affinity rule awareness.

    .DESCRIPTION
        Two-pass algorithm:

        Pass 1 — Compliance (hard-rule violations in the current placement)
          For each enforced rule that is currently violated, Find-MigrationCandidates selects
          the best (VM, destination) pair that resolves the violation without introducing any
          new hard-rule violations. These migrations are added to the plan first, ahead of any
          happiness-based recommendations, and the simulated cluster state is updated so that
          subsequent decisions account for them.

        Pass 2 — Happiness (load balancing)
          Each VM below the aggression-level happiness threshold is evaluated against every
          candidate destination node. The rule impact of each proposed move is checked:
            • Hard violation → destination excluded.
            • Soft violation → configurable score penalty applied to the projected happiness.
            • Fixes a violation → configurable score bonus applied.
          Only moves whose net improvement (post-adjustment) meets the aggression threshold
          are included in the plan.

    .PARAMETER RuleSet
        Array of affinity / anti-affinity rule objects returned by Get-AffinityRuleSet.
        Pass an empty array or omit to disable rule checking entirely.

    .PARAMETER SoftRuleViolationPenalty
        Points subtracted from a candidate destination's projected happiness score when the
        move would break a soft (non-enforced) rule (default: 25).

    .PARAMETER RuleComplianceBonus
        Points added to a candidate's projected score when the move fixes an existing
        soft-rule violation (default: 25). Hard-rule compliance migrations are always
        recommended regardless of the happiness improvement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3,

        [float]$CpuWeight    = 0.5,
        [float]$MemoryWeight = 0.5,

        [float]$MaxDestinationNetworkUtil    = 70.0,
        [int]  $DestinationMemoryReserveMB  = 512,

        [PSCustomObject[]]$RuleSet                  = @(),
        [float]           $SoftRuleViolationPenalty = 25.0,
        [float]           $RuleComplianceBonus      = 25.0,

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

    # Score all running VMs (needed by both passes)
    $vmScores = foreach ($vm in $Snapshot.VMs) {
        $hostMetrics = $Snapshot.Nodes | Where-Object { $_.NodeName -eq $vm.HostNode }
        if (-not $hostMetrics) { continue }
        Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics `
                            -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
    }

    # Mutable simulated node state — updated as migrations are planned
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

    # ── Helper: simulate a VM on a candidate node and score it ────────────────
    $simulateAndScore = {
        param($vm, $candidate)

        $cpuImpact = ($vm.CpuUtilization / 100.0) *
                     ($vm.ProcessorCount / $candidate.LogicalProcessorCount) * 100.0

        $simHost = [PSCustomObject]@{
            NodeName              = $candidate.NodeName
            CpuUtilization        = [Math]::Min(100.0, $candidate.CpuUtilization + $cpuImpact)
            TotalMemoryMB         = $candidate.TotalMemoryMB
            AvailableMemoryMB     = $candidate.AvailableMemoryMB - $vm.MemoryAssignedMB
            LogicalProcessorCount = $candidate.LogicalProcessorCount
            NetworkUtilization    = $candidate.NetworkUtilization
        }

        $simPressure = $vm.MemoryPressure
        if ($vm.DynamicMemoryEnabled -and
            $candidate.AvailableMemoryMB -gt ($vm.MemoryAssignedMB * 1.5)) {
            $simPressure = [Math]::Min($vm.MemoryPressure, 100.0)
        }

        $simVm = [PSCustomObject]@{
            VMName               = $vm.VMName
            HostNode             = $candidate.NodeName
            CpuUtilization       = $vm.CpuUtilization
            ProcessorCount       = $vm.ProcessorCount
            MemoryAssignedMB     = $vm.MemoryAssignedMB
            MemoryDemandMB       = $vm.MemoryDemandMB
            DynamicMemoryEnabled = $vm.DynamicMemoryEnabled
            MemoryPressure       = $simPressure
        }

        Measure-VmHappiness -VmMetrics $simVm -HostMetrics $simHost `
                            -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
    }

    # ── Helper: update simulated node state after a planned migration ─────────
    $applySimulatedMove = {
        param($vm, $srcName, $dstName)
        $src = $simNodes[$srcName]
        $dst = $simNodes[$dstName]
        $srcRelief = ($vm.CpuUtilization/100.0) * ($vm.ProcessorCount/$src.LogicalProcessorCount) * 100.0
        $dstLoad   = ($vm.CpuUtilization/100.0) * ($vm.ProcessorCount/$dst.LogicalProcessorCount) * 100.0
        $src.CpuUtilization    = [Math]::Max(0.0,   $src.CpuUtilization   - $srcRelief)
        $src.AvailableMemoryMB = $src.AvailableMemoryMB + $vm.MemoryAssignedMB
        $dst.CpuUtilization    = [Math]::Min(100.0, $dst.CpuUtilization   + $dstLoad)
        $dst.AvailableMemoryMB = $dst.AvailableMemoryMB - $vm.MemoryAssignedMB
    }

    # ── Helper: get cluster possible-owners for a VM ──────────────────────────
    $getPossibleOwners = {
        param($vmName)
        try {
            (Get-ClusterOwnerNode -Cluster $ClusterName `
                                  -Group "Virtual Machine $vmName" `
                                  -ErrorAction Stop).OwnerNodes.Name
        } catch {
            $Snapshot.Nodes | Select-Object -ExpandProperty NodeName
        }
    }

    # ── Helper: basic destination filter (network, memory, ownership) ─────────
    $basicFilter = {
        param($vm, $possibleOwners, $excludeNode)
        $simNodes.Values | Where-Object {
            $_.NodeName -ne $excludeNode -and
            ($possibleOwners -contains $_.NodeName) -and
            $_.NetworkUtilization -lt $MaxDestinationNetworkUtil -and
            ($_.AvailableMemoryMB - $vm.MemoryAssignedMB) -ge $DestinationMemoryReserveMB
        }
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 1 — Compliance migrations (fix enforced-rule violations first)
    # ════════════════════════════════════════════════════════════════════════════
    if ($RuleSet -and $RuleSet.Count -gt 0) {
        $hardViolations = @(Test-AffinityCompliance -Snapshot $Snapshot -RuleSet $RuleSet |
                            Where-Object { $_.Enforced })

        foreach ($violation in $hardViolations) {
            $movable = @($violation.VMs | Where-Object { -not $scheduledVMs.Contains($_) })
            if ($movable.Count -eq 0) { continue }

            $bestFix   = $null
            $bestScore = -1

            foreach ($vmName in $movable) {
                $vm = $Snapshot.VMs | Where-Object { $_.VMName -eq $vmName }
                if (-not $vm) { continue }

                $possibleOwners = & $getPossibleOwners $vmName
                $candidates     = & $basicFilter $vm $possibleOwners $vm.HostNode

                foreach ($candidate in $candidates) {
                    $impact = Get-MigrationRuleImpact -VMName $vmName `
                                                      -DestinationNode $candidate.NodeName `
                                                      -Snapshot $Snapshot -RuleSet $RuleSet

                    # Skip destinations that break another hard rule or don't fix this one
                    if ($impact.HasHardViolation -or -not $impact.FixesViolation) { continue }

                    $projected = & $simulateAndScore $vm $candidate
                    if ($projected.HappinessScore -gt $bestScore) {
                        $bestScore = $projected.HappinessScore
                        $currentScoreObj = $vmScores | Where-Object { $_.VMName -eq $vmName }
                        $bestFix = [PSCustomObject]@{
                            VMName             = $vmName
                            VMId               = $vm.VMId
                            SourceNode         = $vm.HostNode
                            DestinationNode    = $candidate.NodeName
                            CurrentScore       = $currentScoreObj.HappinessScore
                            ProjectedScore     = [Math]::Round($projected.HappinessScore, 1)
                            Improvement        = [Math]::Round($projected.HappinessScore - $currentScoreObj.HappinessScore, 1)
                            CpuHappinessBefore = $currentScoreObj.CpuHappiness
                            MemHappinessBefore = $currentScoreObj.MemHappiness
                            CpuHappinessAfter  = [Math]::Round($projected.CpuHappiness, 1)
                            MemHappinessAfter  = [Math]::Round($projected.MemHappiness, 1)
                            ComplianceReason   = $violation.Description
                        }
                    }
                }
            }

            if ($bestFix) {
                $migrations.Add($bestFix)
                [void]$scheduledVMs.Add($bestFix.VMName)
                $fixVm = $Snapshot.VMs | Where-Object { $_.VMName -eq $bestFix.VMName }
                & $applySimulatedMove $fixVm $bestFix.SourceNode $bestFix.DestinationNode
            } else {
                Write-Verbose "  No valid destination found to resolve: $($violation.Description)"
            }
        }
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 2 — Happiness-based migrations (load balancing)
    # ════════════════════════════════════════════════════════════════════════════
    $unhappyVMs = $vmScores |
                  Where-Object { $_.HappinessScore -lt $happinessThreshold } |
                  Sort-Object HappinessScore   # most unhappy first

    foreach ($score in $unhappyVMs) {
        if ($scheduledVMs.Contains($score.VMName)) { continue }

        $vm = $Snapshot.VMs | Where-Object { $_.VMName -eq $score.VMName }
        if (-not $vm) { continue }

        $possibleOwners  = & $getPossibleOwners $score.VMName
        $candidates      = & $basicFilter $vm $possibleOwners $score.HostNode

        if (-not $candidates) { continue }

        $bestMigration   = $null
        $bestImprovement = 0.0

        foreach ($candidate in $candidates) {
            # Rule impact check
            $impact = if ($RuleSet -and $RuleSet.Count -gt 0) {
                Get-MigrationRuleImpact -VMName $vm.VMName `
                                        -DestinationNode $candidate.NodeName `
                                        -Snapshot $Snapshot -RuleSet $RuleSet
            } else {
                [PSCustomObject]@{ HasHardViolation=$false; HasSoftViolation=$false; FixesViolation=$false }
            }

            if ($impact.HasHardViolation) { continue }

            $projected = & $simulateAndScore $vm $candidate

            # Apply rule-aware score adjustments
            $adjustedScore = $projected.HappinessScore
            if ($impact.HasSoftViolation) { $adjustedScore = [Math]::Max(0,   $adjustedScore - $SoftRuleViolationPenalty) }
            if ($impact.FixesViolation)   { $adjustedScore = [Math]::Min(100, $adjustedScore + $RuleComplianceBonus) }

            $improvement = $adjustedScore - $score.HappinessScore

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
                    ComplianceReason   = $null
                }
            }
        }

        if ($null -eq $bestMigration -or $bestImprovement -lt $improvementThreshold) { continue }

        $migrations.Add($bestMigration)
        [void]$scheduledVMs.Add($bestMigration.VMName)
        & $applySimulatedMove $vm $bestMigration.SourceNode $bestMigration.DestinationNode
    }

    # Leading comma only on the empty case — see Get-AffinityRuleSet.ps1 for why
    # it must NOT be applied unconditionally (it would break single-recommendation
    # callers that expect the bare migration object, not a 1-element array).
    if ($migrations.Count -eq 0) { return ,@() }
    return $migrations
}
