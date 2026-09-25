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

    .PARAMETER ExcludedVMs
        VM names pinned to Manual automation (see Set-HvDRSVMAutomationLevel) that
        must never be chosen as the VM to move, in either pass. Invoke-HvDRS never
        executes a migration for one of these anyway, so letting the planner select
        one — as the compliance fix for a hard-rule violation, or as the happiness
        pick — only produces a recommendation that will be silently skipped at
        execution time while a different VM that actually could have moved is
        never considered. They remain fully present in -Snapshot for scoring,
        compliance-violation detection, and destination-capacity accounting; they
        are only excluded from being a move's *source* VM.
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

        [string[]]$ExcludedVMs = @(),

        [Parameter(Mandatory)]
        [string]$ClusterName
    )

    $excluded = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExcludedVMs)

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

    # Mutable simulated placement (VMName → HostNode) — updated as migrations are
    # planned and passed to Get-MigrationRuleImpact, so each rule check sees every
    # move already planned in this pass rather than the original snapshot placement.
    $simPlacement = @{}
    foreach ($vm in $Snapshot.VMs) { $simPlacement[$vm.VMName] = $vm.HostNode }

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
        $simPlacement[$vm.VMName] = $dstName
    }

    # ── Helper: get cluster possible-owners for a VM ──────────────────────────
    # Possible owners live on the VM *resource* ("Virtual Machine <name>"), not on
    # the role/group (named after the VM itself), whose owner list is the
    # *preferred* owners — usually empty. An empty possible-owner list means no
    # restriction, as does a lookup failure (e.g. a non-default resource name).
    $getPossibleOwners = {
        param($vmName)
        $allNodes = @($Snapshot.Nodes | Select-Object -ExpandProperty NodeName)
        try {
            $owners = @((Get-ClusterOwnerNode -Cluster $ClusterName `
                                              -Resource "Virtual Machine $vmName" `
                                              -ErrorAction Stop).OwnerNodes |
                        ForEach-Object { $_.Name })
            if ($owners.Count -gt 0) { $owners } else { $allNodes }
        } catch {
            Write-Verbose "  Possible-owner lookup failed for '$vmName' ($_) — treating all nodes as eligible."
            $allNodes
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

    # ── Helper: how badly a single enforced rule is currently violated ─────────
    # 0 = satisfied. Used by Pass 1 to recognize a move that only partially
    # resolves a rule spanning 3+ VMs (e.g. three VMs sharing one host under a
    # hard anti-affinity rule — no single move can fully separate all three),
    # so that move is still taken instead of being rejected outright the way a
    # strictly binary "is it fixed yet?" check would.
    $ruleSeverity = {
        param($rule, $placement)
        switch ($rule.Type) {
            'VmVmAffinity' {
                $hosts = @($rule.VMs | Where-Object { $placement.ContainsKey($_) } | ForEach-Object { $placement[$_] })
                if ($hosts.Count -eq 0) { return 0 }
                # Excess distinct hosts beyond the one they should all share
                return [Math]::Max(0, (@($hosts | Select-Object -Unique)).Count - 1)
            }
            'VmVmAntiAffinity' {
                $hosts = @($rule.VMs | Where-Object { $placement.ContainsKey($_) } | ForEach-Object { $placement[$_] })
                if ($hosts.Count -eq 0) { return 0 }
                # VMs "doubled up" beyond one-per-host — 0 when every member has its own host
                return [Math]::Max(0, $hosts.Count - (@($hosts | Select-Object -Unique)).Count)
            }
            'VmHostAffinity' {
                return @($rule.VMs | Where-Object {
                    $placement.ContainsKey($_) -and ($rule.Hosts -notcontains $placement[$_])
                }).Count
            }
            'VmHostAntiAffinity' {
                return @($rule.VMs | Where-Object {
                    $placement.ContainsKey($_) -and ($rule.Hosts -contains $placement[$_])
                }).Count
            }
            default { return 0 }
        }
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 1 — Compliance migrations (fix enforced-rule violations first)
    # ════════════════════════════════════════════════════════════════════════════
    # Iterates over the enforced rules themselves (via $ruleSeverity), not a
    # one-shot list of Test-AffinityCompliance violations: a rule spanning 3+
    # VMs (e.g. a hard anti-affinity group of three VMs sharing one host) can
    # need more than one move to fully satisfy, and no single move may resolve
    # it outright. Each iteration re-evaluates every violated rule's severity
    # against the current simulated placement and takes whichever move reduces
    # some rule's severity the most (ties broken by projected happiness),
    # repeating until every enforced rule is satisfied or no move helps at all.
    if ($RuleSet -and $RuleSet.Count -gt 0) {
        $enforcedRules = @($RuleSet | Where-Object {
            $_.Enforced -and $_.Type -in @('VmVmAffinity', 'VmVmAntiAffinity', 'VmHostAffinity', 'VmHostAntiAffinity')
        })

        # Generous, non-load-bearing safety cap — see Find-StorageMigrationCandidates'
        # matching per-source loop for the same reasoning. Each accepted iteration
        # strictly reduces some rule's severity, which is bounded by VM count, so
        # this always terminates well before the cap.
        $maxComplianceIterations = $Snapshot.VMs.Count + $enforcedRules.Count + 1

        for ($iter = 0; $iter -lt $maxComplianceIterations; $iter++) {
            $violatedRules = @($enforcedRules | Where-Object { (& $ruleSeverity $_ $simPlacement) -gt 0 })
            if ($violatedRules.Count -eq 0) { break }

            $bestFix             = $null
            $bestFixSeverityDrop = 0
            $bestFixScore        = -1

            foreach ($rule in $violatedRules) {
                $currentSeverity = & $ruleSeverity $rule $simPlacement
                $movable = @($rule.VMs | Where-Object {
                    $simPlacement.ContainsKey($_) -and -not $scheduledVMs.Contains($_) -and -not $excluded.Contains($_)
                })

                foreach ($vmName in $movable) {
                    $vm = $Snapshot.VMs | Where-Object { $_.VMName -eq $vmName }
                    if (-not $vm) { continue }

                    $possibleOwners = & $getPossibleOwners $vmName
                    $candidates     = & $basicFilter $vm $possibleOwners $simPlacement[$vmName]

                    foreach ($candidate in $candidates) {
                        $impact = Get-MigrationRuleImpact -VMName $vmName `
                                                          -DestinationNode $candidate.NodeName `
                                                          -Snapshot $Snapshot -RuleSet $RuleSet `
                                                          -Placement $simPlacement

                        # Never accept a move that breaks a DIFFERENT enforced rule
                        if ($impact.HasHardViolation) { continue }

                        $hypothetical = $simPlacement.Clone()
                        $hypothetical[$vmName] = $candidate.NodeName
                        $severityDrop = $currentSeverity - (& $ruleSeverity $rule $hypothetical)
                        if ($severityDrop -le 0) { continue }   # no progress on this rule

                        $projected = & $simulateAndScore $vm $candidate
                        if ($severityDrop -gt $bestFixSeverityDrop -or
                            ($severityDrop -eq $bestFixSeverityDrop -and $projected.HappinessScore -gt $bestFixScore)) {
                            $bestFixSeverityDrop = $severityDrop
                            $bestFixScore        = $projected.HappinessScore
                            $currentScoreObj     = $vmScores | Where-Object { $_.VMName -eq $vmName }
                            $newSeverity         = $currentSeverity - $severityDrop
                            $bestFix = [PSCustomObject]@{
                                VMName             = $vmName
                                VMId               = $vm.VMId
                                SourceNode         = $simPlacement[$vmName]
                                DestinationNode    = $candidate.NodeName
                                CurrentScore       = $currentScoreObj.HappinessScore
                                ProjectedScore     = [Math]::Round($projected.HappinessScore, 1)
                                Improvement        = [Math]::Round($projected.HappinessScore - $currentScoreObj.HappinessScore, 1)
                                CpuHappinessBefore = $currentScoreObj.CpuHappiness
                                MemHappinessBefore = $currentScoreObj.MemHappiness
                                CpuHappinessAfter  = [Math]::Round($projected.CpuHappiness, 1)
                                MemHappinessAfter  = [Math]::Round($projected.MemHappiness, 1)
                                ComplianceReason   = if ($newSeverity -eq 0) {
                                    "Satisfies enforced $($rule.Type) rule '$($rule.Name)'"
                                } else {
                                    "Partially satisfies enforced $($rule.Type) rule '$($rule.Name)' ($newSeverity violation(s) remaining)"
                                }
                            }
                        }
                    }
                }
            }

            if (-not $bestFix) {
                Write-Verbose ("  No move improves compliance for: {0}" -f
                    (($violatedRules | ForEach-Object { $_.Name }) -join ', '))
                break
            }

            $migrations.Add($bestFix)
            [void]$scheduledVMs.Add($bestFix.VMName)
            $fixVm = $Snapshot.VMs | Where-Object { $_.VMName -eq $bestFix.VMName }
            & $applySimulatedMove $fixVm $bestFix.SourceNode $bestFix.DestinationNode
        }
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 2 — Happiness-based migrations (load balancing)
    # ════════════════════════════════════════════════════════════════════════════
    $unhappyVMs = $vmScores |
                  Where-Object { $_.HappinessScore -lt $happinessThreshold } |
                  Sort-Object HappinessScore   # most unhappy first

    foreach ($score in $unhappyVMs) {
        if ($scheduledVMs.Contains($score.VMName) -or $excluded.Contains($score.VMName)) { continue }

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
                                        -Snapshot $Snapshot -RuleSet $RuleSet `
                                        -Placement $simPlacement
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
