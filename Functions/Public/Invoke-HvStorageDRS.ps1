function Invoke-HvStorageDRS {
    <#
    .SYNOPSIS
        Hyper-V Storage DRS — balances Cluster Shared Volume utilization by
        live-migrating VM storage between CSVs.

    .DESCRIPTION
        Scores each CSV on a 0–100 Happiness scale (space-based, optionally
        I/O-latency-weighted) and identifies VMs whose storage should move to a
        less-loaded CSV. Uses the same aggression-level model as Invoke-HvDRS.

        Migrations are executed via Move-VMStorage (storage live migration), which
        moves all VHDs and configuration files while the VM remains running.

        Use -WhatIf to preview recommendations without moving any data.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER AggressionLevel
        Controls sensitivity (1–5, default 3). Higher values trigger migrations
        for smaller happiness deficits. Uses the same thresholds as Invoke-HvDRS.

        Level  CSV threshold  Min improvement
        -----  ------------  ---------------
          1        < 30           > 40
          2        < 40           > 30
          3        < 50           > 20  (default)
          4        < 60           > 15
          5        < 70           > 10

    .PARAMETER SampleCount
        Number of I/O counter samples to average per CSV (default: 3).
        Set to 0 to skip I/O collection entirely (space-only scoring).

    .PARAMETER SampleIntervalSeconds
        Seconds between I/O counter samples (default: 5).

    .PARAMETER SpaceWeight
        Relative weight of space happiness in the combined CSV score (default: 0.7).

    .PARAMETER IoWeight
        Relative weight of I/O (latency) happiness in the combined score (default: 0.3).
        Automatically dropped to 0 for any CSV where latency counters are unavailable.

    .PARAMETER MinFreeGBReserve
        Minimum free space (GB) that must remain on the destination CSV after the
        VM's VHDs land (default: 50 GB).

    .PARAMETER RecommendOnly
        Print the migration plan but never call Move-VMStorage.

    .PARAMETER MaintenanceLockFile
        Shares the same lock file as Invoke-HvDRS so a single maintenance window
        suppresses both compute and storage migrations.
        Default: $env:ProgramData\HvDRS\maintenance.lock

    .EXAMPLE
        # Dry run — print recommendations without moving data
        Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -WhatIf

    .EXAMPLE
        # Space-only scoring (skip I/O counter collection)
        Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -SampleCount 0

    .EXAMPLE
        # Aggressive rebalancing with larger headroom requirement
        Invoke-HvStorageDRS -ClusterName 'PROD-CLUSTER' -AggressionLevel 5 -MinFreeGBReserve 100
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string] $ClusterName,

        [ValidateRange(1, 5)]
        [int]   $AggressionLevel       = 3,

        [int]   $SampleCount           = 3,
        [int]   $SampleIntervalSeconds = 5,

        [ValidateRange(0.0, 1.0)]
        [float] $SpaceWeight           = 0.7,

        [ValidateRange(0.0, 1.0)]
        [float] $IoWeight              = 0.3,

        [int]   $MinFreeGBReserve      = 50,

        [switch] $RecommendOnly,

        [string] $MaintenanceLockFile  = (Join-Path $env:ProgramData 'HvDRS\maintenance.lock')
    )

    # ── Resolve cluster ────────────────────────────────────────────────────────
    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    $ts = { "[{0}]" -f [DateTime]::Now.ToString('HH:mm:ss') }

    # ── Execution mode ─────────────────────────────────────────────────────────
    $maintenanceActive = Test-Path -LiteralPath $MaintenanceLockFile
    $willMigrate       = -not $RecommendOnly -and -not $maintenanceActive

    $modeLabel = if ($maintenanceActive) {
        $lockContent = Get-Content -LiteralPath $MaintenanceLockFile -ErrorAction SilentlyContinue
        "MAINTENANCE ($lockContent)"
    } elseif ($RecommendOnly) { 'RECOMMEND-ONLY' } else { 'AUTO-MIGRATE' }

    Write-Host ("{0} HvStorageDRS starting — Cluster: {1}  Aggression: {2}  Weights: Space={3} IO={4}  Reserve: {5} GB  Mode: {6}" -f
        (& $ts), $ClusterName, $AggressionLevel, $SpaceWeight, $IoWeight, $MinFreeGBReserve, $modeLabel)

    if ($maintenanceActive) {
        $lockContent = Get-Content -LiteralPath $MaintenanceLockFile -ErrorAction SilentlyContinue
        Write-Host ("{0} Maintenance lock active ({1}). No storage migrations will run." -f
            (& $ts), $lockContent) -ForegroundColor Yellow
    }

    # ── Phase 1: Collect storage snapshot ─────────────────────────────────────
    $ioLabel = if ($SampleCount -gt 0) { "samples=$SampleCount, interval=${SampleIntervalSeconds}s" } else { 'disabled' }
    Write-Host ("{0} Collecting storage metrics (I/O: {1})..." -f (& $ts), $ioLabel)

    $snapshot = Get-StorageSnapshot -ClusterName $ClusterName `
                                    -SampleCount $SampleCount `
                                    -SampleIntervalSeconds $SampleIntervalSeconds `
                                    -Verbose:($VerbosePreference -ne 'SilentlyContinue')

    if ($snapshot.CSVs.Count -eq 0) {
        Write-Host ("{0} No Cluster Shared Volumes found. Nothing to balance." -f (& $ts))
        return
    }

    Write-Host ("{0} Snapshot: {1} CSV(s), {2} VM(s) with CSV storage." -f
        (& $ts), $snapshot.CSVs.Count, $snapshot.VMs.Count)

    # ── Phase 2: CSV space + I/O summary ──────────────────────────────────────
    Write-Host ''
    Write-Host '── CSV Summary ───────────────────────────────────────────────────────────────'
    $snapshot.CSVs | Sort-Object SpaceUsedPct -Descending | Format-Table -AutoSize -Property `
        @{ N='CSV';         E={ $_.Name } },
        @{ N='Owner';       E={ $_.OwnerNode } },
        @{ N='Total GB';    E={ '{0:N1}' -f $_.TotalGB } },
        @{ N='Used GB';     E={ '{0:N1}' -f $_.UsedGB } },
        @{ N='Free GB';     E={ '{0:N1}' -f $_.FreeGB } },
        @{ N='Used %';      E={ '{0:N1}' -f $_.SpaceUsedPct } },
        @{ N='Read IOPS';   E={ if ($null -ne $_.ReadIOPS)  { '{0:N0}' -f $_.ReadIOPS  } else { 'N/A' } } },
        @{ N='Write IOPS';  E={ if ($null -ne $_.WriteIOPS) { '{0:N0}' -f $_.WriteIOPS } else { 'N/A' } } },
        @{ N='Latency ms';  E={ if ($null -ne $_.LatencyMs) { '{0:N2}' -f $_.LatencyMs } else { 'N/A' } } }

    # ── Phase 3: Score all CSVs ────────────────────────────────────────────────
    $csvScores = foreach ($csv in $snapshot.CSVs) {
        Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight $SpaceWeight -IoWeight $IoWeight
    }

    Write-Host '── CSV Happiness Scores ──────────────────────────────────────────────────────'
    $csvScores | Sort-Object HappinessScore | Format-Table -AutoSize -Property `
        @{ N='CSV';         E={ $_.CsvName } },
        @{ N='Space Happy'; E={ '{0:N1}' -f $_.SpaceHappiness } },
        @{ N='IO Happy';    E={ if ($null -ne $_.IoHappiness) { '{0:N1}' -f $_.IoHappiness } else { 'N/A (space-only)' } } },
        @{ N='Score';       E={ '{0:N1}' -f $_.HappinessScore } },
        @{ N='Status';      E={
            if    ($_.HappinessScore -ge 80) { 'Healthy' }
            elseif ($_.HappinessScore -ge 50) { 'Pressured' }
            else                             { 'CRITICAL' }
        }}

    # ── Phase 4: Find storage migration candidates ─────────────────────────────
    $migrations = Find-StorageMigrationCandidates `
                      -Snapshot $snapshot `
                      -AggressionLevel $AggressionLevel `
                      -SpaceWeight $SpaceWeight `
                      -IoWeight $IoWeight `
                      -MinFreeGBReserve $MinFreeGBReserve `
                      -Verbose:($VerbosePreference -ne 'SilentlyContinue')

    if (-not $migrations -or $migrations.Count -eq 0) {
        Write-Host ("{0} Storage is balanced at aggression level {1}. No migrations needed." -f
            (& $ts), $AggressionLevel)
        return
    }

    Write-Host ''
    Write-Host ('── {0} Storage Migration Recommendation(s) ────────────────────────────────────' -f $migrations.Count)
    $migrations | Format-Table -AutoSize -Property `
        @{ N='VM';           E={ $_.VMName } },
        @{ N='Host';         E={ $_.HostNode } },
        @{ N='From CSV';     E={ $_.SourceCSVName } },
        @{ N='To CSV';       E={ $_.DestinationCSVName } },
        @{ N='Data GB';      E={ '{0:N1}' -f $_.TotalVhdGB } },
        @{ N='Src Score';    E={ '{0} → {1}' -f $_.SourceScoreBefore, $_.SourceScoreAfter } },
        @{ N='Dst Score';    E={ '{0} → {1}' -f $_.DestScoreBefore,   $_.DestScoreAfter } },
        @{ N='Src Free GB';  E={ '{0:N0} → {1:N0}' -f $_.SourceFreeGBBefore, $_.SourceFreeGBAfter } },
        @{ N='Delta';        E={ '+{0}' -f $_.Improvement } }

    # ── Phase 5: Execute or preview ────────────────────────────────────────────
    if (-not $willMigrate) {
        $reason = if ($maintenanceActive) { 'maintenance lock is active' } else { '-RecommendOnly was specified' }
        Write-Host ("{0} Skipping storage migration execution — {1}." -f (& $ts), $reason)
        Write-Host ''
        Write-Host ("{0} HvStorageDRS pass complete — {1} recommendation(s), no migrations executed." -f
            (& $ts), $migrations.Count)
        return
    }

    $succeeded = 0
    $failed    = 0

    foreach ($migration in $migrations) {
        $action = "Storage live-migrate '{0}' ({1:N1} GB VHDs) from '{2}' to '{3}'" -f
                  $migration.VMName, $migration.TotalVhdGB,
                  $migration.SourceCSVName, $migration.DestinationCSVName

        if (-not $PSCmdlet.ShouldProcess($migration.VMName, $action)) { continue }

        Write-Host ("{0} Moving '{1}' ({2:N1} GB): '{3}' → '{4}' ..." -f
            (& $ts), $migration.VMName, $migration.TotalVhdGB,
            $migration.SourceCSVName, $migration.DestinationCSVName)

        try {
            Move-VMStorage -ComputerName $migration.HostNode `
                           -VMName       $migration.VMName `
                           -DestinationStoragePath $migration.DestinationCSV `
                           -ErrorAction  Stop

            Write-Host ("{0}   Done. Source CSV score {1} → {2} (+{3})" -f
                (& $ts), $migration.SourceScoreBefore, $migration.SourceScoreAfter, $migration.Improvement)
            $succeeded++
        } catch {
            Write-Warning ("Storage migration of '{0}' failed: {1}" -f $migration.VMName, $_)
            $failed++
        }
    }

    if ($PSCmdlet.ShouldProcess('summary', 'Report')) {
        Write-Host ''
        Write-Host ("{0} HvStorageDRS pass complete — {1} migrated, {2} failed." -f
            (& $ts), $succeeded, $failed)
    }
}
