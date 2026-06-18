function Find-StorageMigrationCandidates {
    <#
    .SYNOPSIS
        Identifies VMs whose VHDs should be moved to a different CSV to balance
        storage space and I/O load across the cluster.

    .DESCRIPTION
        Algorithm:

          1. Score every CSV with Measure-CsvHappiness.
          2. Identify CSVs whose current (simulated) score is below the
             aggression-level happiness threshold, sorted most→least unhappy.
          3. For each unhappy source CSV, evaluate every combination of
             (unscheduled VM on source, candidate destination CSV):
               • Candidate must have enough headroom after receiving the VM's
                 VHDs: (FreeGB – vm.TotalVhdGB) >= MinFreeGBReserve.
               • Simulate source after VM departs → projectedSrcScore.
               • Simulate destination after VM arrives → projectedDstScore.
               • improvement = projectedSrcScore − currentSimSrcScore.
          4. Pick the (VM, destination) pair with the highest improvement.
          5. If improvement meets the aggression-level minimum, add to the plan.
          6. Update simulated CSV state (FreeGB) before moving to the next source.

        The simulated state ensures the greedy planner does not over-commit a
        single destination CSV across multiple planned moves.

    .OUTPUTS
        List of PSCustomObjects: VMName, VMId, HostNode, SourceCSV, SourceCSVName,
        DestinationCSV, DestinationCSVName, VHDCount, TotalVhdGB,
        SourceFreeGBBefore, SourceFreeGBAfter, DestFreeGBBefore, DestFreeGBAfter,
        SourceScoreBefore, SourceScoreAfter, DestScoreBefore, DestScoreAfter,
        Improvement.
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

        [int]   $MinFreeGBReserve  = 50
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

                $improvement = $projectedSrcScore - $currentSrcScore

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
