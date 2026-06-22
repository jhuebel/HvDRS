function Find-StorageMigrationCandidates {
    <#
    .SYNOPSIS
        Identifies VMs whose VHDs should be moved to a different CSV to balance
        storage space and I/O load across the cluster.

    .DESCRIPTION
        Two-pass algorithm, mirroring Find-MigrationCandidates:

        Pass 1 — Storage rule compliance (hard-rule violations in current placement)
          For each enforced storage affinity rule that is currently violated, selects
          the best (VM, destination CSV) pair that resolves the violation without
          introducing any new hard storage-rule violation. These migrations are added
          to the plan first, and the simulated CSV state is updated accordingly.

        Pass 2 — Happiness (space/IO load balancing)
          1. Score every CSV with Measure-CsvHappiness.
          2. Identify CSVs whose current (simulated) score is below the
             aggression-level happiness threshold, sorted most→least unhappy.
          3. For each unhappy source CSV, evaluate every combination of
             (unscheduled VM on source, candidate destination CSV):
               • Candidate must have enough headroom after receiving the VM's
                 VHDs: (FreeGB – vm.TotalVhdGB) >= MinFreeGBReserve.
               • Storage rule impact of the move is checked:
                   - Hard violation → destination excluded.
                   - Soft violation → configurable score penalty applied.
                   - Fixes a violation → configurable score bonus applied.
               • Simulate source after VM departs → projectedSrcScore (rule-adjusted).
               • Simulate destination after VM arrives → projectedDstScore.
               • improvement = adjustedSrcScore − currentSimSrcScore.
          4. Pick the (VM, destination) pair with the highest improvement.
          5. If improvement meets the aggression-level minimum, add to the plan.
          6. Update simulated CSV state (FreeGB) before moving to the next source.

        The simulated state ensures the greedy planner does not over-commit a
        single destination CSV across multiple planned moves.

    .PARAMETER RuleSet
        Array of storage affinity / anti-affinity rule objects (VmVmCsvAffinity,
        VmVmCsvAntiAffinity, VmCsvAffinity, VmCsvAntiAffinity) returned by
        Get-AffinityRuleSet. Pass an empty array or omit to disable rule checking.

    .PARAMETER SoftRuleViolationPenalty
        Points subtracted from a candidate destination's projected source-relief score
        when the move would break a soft (non-enforced) storage rule (default: 25).

    .PARAMETER RuleComplianceBonus
        Points added to a candidate's projected score when the move fixes an existing
        soft storage-rule violation (default: 25). Hard-rule compliance migrations are
        always recommended regardless of the happiness improvement.

    .OUTPUTS
        List of PSCustomObjects: VMName, VMId, HostNode, SourceCSV, SourceCSVName,
        DestinationCSV, DestinationCSVName, VHDCount, TotalVhdGB,
        SourceFreeGBBefore, SourceFreeGBAfter, DestFreeGBBefore, DestFreeGBAfter,
        SourceScoreBefore, SourceScoreAfter, DestScoreBefore, DestScoreAfter,
        Improvement, ComplianceReason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Snapshot,

        [ValidateRange(1, 5)]
        [int]   $AggressionLevel   = 3,

        [ValidateRange(0.0, 1.0)]
        [float] $SpaceWeight       = 0.7,

        [ValidateRange(0.0, 1.0)]
        [float] $IoWeight          = 0.3,

        [int]   $MinFreeGBReserve  = 50,

        [PSCustomObject[]] $RuleSet                  = @(),
        [float]            $SoftRuleViolationPenalty = 25.0,
        [float]            $RuleComplianceBonus      = 25.0
    )

    $thresholds = @{
        1 = @{ Happiness = 30; Improvement = 40 }
        2 = @{ Happiness = 40; Improvement = 30 }
        3 = @{ Happiness = 50; Improvement = 20 }
        4 = @{ Happiness = 60; Improvement = 15 }
        5 = @{ Happiness = 70; Improvement = 10 }
    }
    $happinessThreshold   = $thresholds[$AggressionLevel].Happiness
    $improvementThreshold = $thresholds[$AggressionLevel].Improvement

    # Initial scores — used for SourceScoreBefore / DestScoreBefore in output
    $initialScores = @{}
    foreach ($csv in $Snapshot.CSVs) {
        $s = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight $SpaceWeight -IoWeight $IoWeight
        $initialScores[$csv.Name] = $s.HappinessScore
    }

    # Mutable simulated CSV state keyed by CSV Name
    $simCsvs = @{}
    foreach ($csv in $Snapshot.CSVs) {
        $simCsvs[$csv.Name] = [PSCustomObject]@{
            Name      = $csv.Name
            Path      = $csv.Path
            TotalGB   = $csv.TotalGB
            FreeGB    = $csv.FreeGB
            LatencyMs = $csv.LatencyMs
            ReadIOPS  = $csv.ReadIOPS
            WriteIOPS = $csv.WriteIOPS
        }
    }

    # Path → Name mapping (VMs reference CSVs by path)
    $pathToName = @{}
    foreach ($csv in $Snapshot.CSVs) { $pathToName[$csv.Path] = $csv.Name }

    # VM → current CSV-name mapping (used for rule evaluation)
    $vmCsvName = @{}
    foreach ($vm in $Snapshot.VMs) { $vmCsvName[$vm.VMName] = $pathToName[$vm.PrimaryCSV] }

    # Helper: score a simulated CSV object
    $scoreSimCsv = {
        param($sim)
        $proxy = [PSCustomObject]@{
            Name      = $sim.Name
            TotalGB   = $sim.TotalGB
            FreeGB    = $sim.FreeGB
            LatencyMs = $sim.LatencyMs
        }
        (Measure-CsvHappiness -CsvMetrics $proxy -SpaceWeight $SpaceWeight -IoWeight $IoWeight).HappinessScore
    }

    $scheduledVMs = [System.Collections.Generic.HashSet[string]]::new()
    $migrations   = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 1 — Storage rule compliance (fix enforced-rule violations first)
    # ════════════════════════════════════════════════════════════════════════════
    if ($RuleSet -and $RuleSet.Count -gt 0) {
        $hardViolations = @(Test-StorageAffinityCompliance -Snapshot $Snapshot -RuleSet $RuleSet |
                            Where-Object { $_.Enforced })

        foreach ($violation in $hardViolations) {
            $movable = @($violation.VMs | Where-Object { -not $scheduledVMs.Contains($_) })
            if ($movable.Count -eq 0) { continue }

            $bestFix   = $null
            $bestScore = -1

            foreach ($vmName in $movable) {
                $vm = $Snapshot.VMs | Where-Object { $_.VMName -eq $vmName }
                if (-not $vm) { continue }

                $srcName = $vmCsvName[$vmName]
                $simSrcForVm = $simCsvs[$srcName]
                if (-not $simSrcForVm) { continue }

                $candidates = $simCsvs.Values | Where-Object {
                    $_.Name -ne $srcName -and
                    ($_.FreeGB - $vm.TotalVhdGB) -ge $MinFreeGBReserve
                }

                foreach ($dst in $candidates) {
                    $impact = Get-StorageMigrationRuleImpact -VMName $vmName -DestinationCsvName $dst.Name `
                                                              -Snapshot $Snapshot -RuleSet $RuleSet

                    if ($impact.HasHardViolation -or -not $impact.FixesViolation) { continue }

                    $dstFreeAfter = $dst.FreeGB - $vm.TotalVhdGB
                    $dstSimCopy   = [PSCustomObject]@{
                        Name = $dst.Name; TotalGB = $dst.TotalGB
                        FreeGB = $dstFreeAfter; LatencyMs = $dst.LatencyMs
                    }
                    $projectedDstScore = & $scoreSimCsv $dstSimCopy

                    if ($projectedDstScore -gt $bestScore) {
                        $bestScore = $projectedDstScore

                        $srcFreeAfter = $simSrcForVm.FreeGB + $vm.TotalVhdGB
                        $srcSimCopy   = [PSCustomObject]@{
                            Name = $simSrcForVm.Name; TotalGB = $simSrcForVm.TotalGB
                            FreeGB = $srcFreeAfter; LatencyMs = $simSrcForVm.LatencyMs
                        }
                        $projectedSrcScore = & $scoreSimCsv $srcSimCopy

                        $bestFix = [PSCustomObject]@{
                            VMName             = $vmName
                            VMId               = $vm.VMId
                            HostNode           = $vm.HostNode
                            SourceCSV          = $simSrcForVm.Path
                            SourceCSVName      = $simSrcForVm.Name
                            DestinationCSV     = $dst.Path
                            DestinationCSVName = $dst.Name
                            VHDCount           = $vm.VHDs.Count
                            TotalVhdGB         = $vm.TotalVhdGB
                            SourceFreeGBBefore = [Math]::Round($simSrcForVm.FreeGB, 1)
                            SourceFreeGBAfter  = [Math]::Round($srcFreeAfter, 1)
                            DestFreeGBBefore   = [Math]::Round($dst.FreeGB, 1)
                            DestFreeGBAfter    = [Math]::Round($dstFreeAfter, 1)
                            SourceScoreBefore  = $initialScores[$srcName]
                            SourceScoreAfter   = [Math]::Round($projectedSrcScore, 1)
                            DestScoreBefore    = $initialScores[$dst.Name]
                            DestScoreAfter     = [Math]::Round($projectedDstScore, 1)
                            Improvement        = [Math]::Round($projectedSrcScore - $initialScores[$srcName], 1)
                            ComplianceReason   = $violation.Description
                        }
                    }
                }
            }

            if ($bestFix) {
                $migrations.Add($bestFix)
                [void]$scheduledVMs.Add($bestFix.VMName)
                $simCsvs[$bestFix.SourceCSVName].FreeGB      += $bestFix.TotalVhdGB
                $simCsvs[$bestFix.DestinationCSVName].FreeGB -= $bestFix.TotalVhdGB
            } else {
                Write-Verbose "  No valid CSV destination found to resolve: $($violation.Description)"
            }
        }
    }

    # ════════════════════════════════════════════════════════════════════════════
    # PASS 2 — Happiness-based migrations (space / IO load balancing)
    # ════════════════════════════════════════════════════════════════════════════
    # Collect unhappy CSVs — re-evaluated each outer iteration via simulated state
    $unhappyCsvNames = $initialScores.GetEnumerator() |
                       Where-Object { $_.Value -lt $happinessThreshold } |
                       Sort-Object Value |
                       Select-Object -ExpandProperty Key

    foreach ($srcName in $unhappyCsvNames) {
        $simSrc = $simCsvs[$srcName]
        if (-not $simSrc) { continue }

        # Re-score against current simulated state; skip if already fixed
        $currentSrcScore = & $scoreSimCsv $simSrc
        if ($currentSrcScore -ge $happinessThreshold) { continue }

        # VMs whose primary storage is on this CSV and not yet scheduled
        $vmsOnSrc = $Snapshot.VMs | Where-Object {
            $pathToName[$_.PrimaryCSV] -eq $srcName -and
            -not $scheduledVMs.Contains($_.VMName)
        }
        if (-not $vmsOnSrc) { continue }

        $bestMigration   = $null
        $bestImprovement = 0.0

        foreach ($vm in $vmsOnSrc) {
            # Candidate destinations: enough headroom after receiving this VM
            $candidates = $simCsvs.Values | Where-Object {
                $_.Name -ne $srcName -and
                ($_.FreeGB - $vm.TotalVhdGB) -ge $MinFreeGBReserve
            }

            foreach ($dst in $candidates) {
                # Storage rule impact check
                $impact = if ($RuleSet -and $RuleSet.Count -gt 0) {
                    Get-StorageMigrationRuleImpact -VMName $vm.VMName -DestinationCsvName $dst.Name `
                                                   -Snapshot $Snapshot -RuleSet $RuleSet
                } else {
                    [PSCustomObject]@{ HasHardViolation=$false; HasSoftViolation=$false; FixesViolation=$false }
                }

                if ($impact.HasHardViolation) { continue }

                # Simulate source after VM departs
                $srcFreeAfter = $simSrc.FreeGB + $vm.TotalVhdGB
                $srcSimCopy   = [PSCustomObject]@{
                    Name = $simSrc.Name; TotalGB = $simSrc.TotalGB
                    FreeGB = $srcFreeAfter; LatencyMs = $simSrc.LatencyMs
                }
                $projectedSrcScore = (Measure-CsvHappiness -CsvMetrics $srcSimCopy -SpaceWeight $SpaceWeight -IoWeight $IoWeight).HappinessScore

                # Simulate destination after VM arrives
                $dstFreeAfter = $dst.FreeGB - $vm.TotalVhdGB
                $dstSimCopy   = [PSCustomObject]@{
                    Name = $dst.Name; TotalGB = $dst.TotalGB
                    FreeGB = $dstFreeAfter; LatencyMs = $dst.LatencyMs
                }
                $projectedDstScore = (Measure-CsvHappiness -CsvMetrics $dstSimCopy -SpaceWeight $SpaceWeight -IoWeight $IoWeight).HappinessScore

                # Apply rule-aware adjustment to the source-relief score used for selection
                $adjustedSrcScore = $projectedSrcScore
                if ($impact.HasSoftViolation) { $adjustedSrcScore = [Math]::Max(0,   $adjustedSrcScore - $SoftRuleViolationPenalty) }
                if ($impact.FixesViolation)   { $adjustedSrcScore = [Math]::Min(100, $adjustedSrcScore + $RuleComplianceBonus) }

                $improvement = $adjustedSrcScore - $currentSrcScore

                if ($improvement -gt $bestImprovement) {
                    $bestImprovement = $improvement
                    $bestMigration = [PSCustomObject]@{
                        VMName             = $vm.VMName
                        VMId               = $vm.VMId
                        HostNode           = $vm.HostNode
                        SourceCSV          = $simSrc.Path
                        SourceCSVName      = $simSrc.Name
                        DestinationCSV     = $dst.Path
                        DestinationCSVName = $dst.Name
                        VHDCount           = $vm.VHDs.Count
                        TotalVhdGB         = $vm.TotalVhdGB
                        SourceFreeGBBefore = [Math]::Round($simSrc.FreeGB, 1)
                        SourceFreeGBAfter  = [Math]::Round($srcFreeAfter, 1)
                        DestFreeGBBefore   = [Math]::Round($dst.FreeGB, 1)
                        DestFreeGBAfter    = [Math]::Round($dstFreeAfter, 1)
                        SourceScoreBefore  = $initialScores[$srcName]
                        SourceScoreAfter   = [Math]::Round($projectedSrcScore, 1)
                        DestScoreBefore    = $initialScores[$dst.Name]
                        DestScoreAfter     = [Math]::Round($projectedDstScore, 1)
                        Improvement        = [Math]::Round($improvement, 1)
                        ComplianceReason   = $null
                    }
                }
            }
        }

        if ($null -eq $bestMigration -or $bestImprovement -lt $improvementThreshold) { continue }

        $migrations.Add($bestMigration)
        [void]$scheduledVMs.Add($bestMigration.VMName)

        # Greedy state update
        $simCsvs[$bestMigration.SourceCSVName].FreeGB      += $bestMigration.TotalVhdGB
        $simCsvs[$bestMigration.DestinationCSVName].FreeGB -= $bestMigration.TotalVhdGB
    }

    return $migrations
}
