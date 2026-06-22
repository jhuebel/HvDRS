function Invoke-HvDRS {
    <#
    .SYNOPSIS
        Hyper-V Distributed Resource Scheduler — balances a Failover Cluster using a VM Happiness metric,
        with optional affinity / anti-affinity rule enforcement.

    .DESCRIPTION
        Inspired by VMware's per-VM happiness model (vSphere 7+ DRS), this function:

          1. Snapshots CPU, memory, and network utilization across all cluster nodes.
          2. Scores each running VM on a 0–100 Happiness scale based on whether
             it is receiving the CPU and memory resources it demands.
          3. Loads affinity / anti-affinity rules and checks current placement for
             violations; enforced (hard) rule violations are remediated first.
          4. Identifies VMs below the aggression-level happiness threshold.
          5. Selects destination nodes using a Network-Aware filter: nodes whose
             NIC utilization exceeds -MaxDestinationNetworkUtil are excluded.
          6. Recommends or executes Live Migrations via Move-ClusterVirtualMachineRole,
             respecting cluster possible-owner constraints and affinity rules.

        Use -WhatIf to preview recommendations without migrating anything.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER AggressionLevel
        Controls sensitivity (1–5, default 3), mirroring VMware DRS aggression levels.
        Higher values trigger migrations for smaller happiness deficits.

        Level  Happiness threshold  Min improvement
        -----  ------------------  ---------------
          1          < 30               > 40
          2          < 40               > 30
          3          < 50               > 20  (default)
          4          < 60               > 15
          5          < 70               > 10

    .PARAMETER SampleCount
        Number of CPU counter samples to average per node (default: 5).

    .PARAMETER SampleIntervalSeconds
        Seconds between CPU counter samples (default: 2).

    .PARAMETER CpuWeight
        Relative weight of CPU happiness in the combined score (default: 0.5).

    .PARAMETER MemoryWeight
        Relative weight of memory happiness in the combined score (default: 0.5).

    .PARAMETER MaxDestinationNetworkUtil
        Network-Aware DRS gate: destination hosts with aggregate NIC utilization at or
        above this percentage are excluded from consideration (default: 70%).

    .PARAMETER DestinationMemoryReserveMB
        Minimum free memory (MB) that must remain on the destination after the VM lands
        (default: 512 MB).

    .PARAMETER RulesPath
        Path to the JSON affinity rule store. If the file does not exist, rule checking
        is skipped. Default: $env:ProgramData\HvDRS\rules.json.
        Manage rules with Add-HvDRSAffinityRule / Get-HvDRSAffinityRule / etc.

    .PARAMETER SoftRuleViolationPenalty
        Score penalty (0–100) applied to the projected happiness of a VM when a proposed
        migration would break a soft affinity rule (default: 25).

    .PARAMETER RuleComplianceBonus
        Score bonus (0–100) added to the projected happiness when a migration would fix
        an existing soft rule violation (default: 25).

    .PARAMETER RecommendOnly
        Collect metrics, score VMs, and print recommendations — but never execute migrations.
        Useful when scheduling periodic monitoring passes that should not trigger live migrations.
        Unlike -WhatIf (which is a one-time interactive override), this switch is designed to be
        baked into a Task Scheduler invocation for a permanently read-only scheduled job.

    .PARAMETER MaintenanceLockFile
        Path to a lock file that temporarily suppresses all migration execution when present.
        If the file exists, HvDRS will still collect metrics and score VMs but will not migrate
        any workloads. Default: $env:ProgramData\HvDRS\maintenance.lock

        Use Enable-HvDRSMaintenance / Disable-HvDRSMaintenance to manage the lock file.

    .EXAMPLE
        # Dry run — see what would be moved without touching anything
        Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -WhatIf

    .EXAMPLE
        # Run with high aggression; auto-migrate anything below score 70
        Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -AggressionLevel 5

    .EXAMPLE
        # Monitoring-only scheduled task — never migrates, just reports
        Invoke-HvDRS -ClusterName 'PROD-CLUSTER' -RecommendOnly

    .EXAMPLE
        # Pause migrations for a maintenance window, then resume
        Enable-HvDRSMaintenance -ClusterName 'PROD-CLUSTER' -Reason 'Patch Tuesday'
        # ... perform maintenance ...
        Disable-HvDRSMaintenance -ClusterName 'PROD-CLUSTER'

    .EXAMPLE
        # Weight memory pressure more heavily than CPU, use a custom rules file
        Invoke-HvDRS -CpuWeight 0.3 -MemoryWeight 0.7 -RulesPath D:\config\hvdrs-rules.json
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$ClusterName,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3,

        [int]$SampleCount = 5,

        [int]$SampleIntervalSeconds = 2,

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

        [switch]$RecommendOnly,

        [string]$MaintenanceLockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    # ── Resolve cluster ────────────────────────────────────────────────────────
    if (-not $ClusterName) {
        try {
            $ClusterName = (Get-Cluster -ErrorAction Stop).Name
        } catch {
            throw "No -ClusterName specified and no local cluster detected. $_"
        }
    }

    $ts = { "[{0}]" -f [DateTime]::Now.ToString('HH:mm:ss') }

    # ── Resolve execution mode ─────────────────────────────────────────────────
    $maintenanceActive = Test-Path -LiteralPath $MaintenanceLockFile
    $willMigrate       = -not $RecommendOnly -and -not $maintenanceActive

    $modeLabel = if ($maintenanceActive) {
        $lockContent = Get-Content -LiteralPath $MaintenanceLockFile -ErrorAction SilentlyContinue
        "MAINTENANCE ($lockContent)"
    } elseif ($RecommendOnly) {
        'RECOMMEND-ONLY'
    } else {
        'AUTO-MIGRATE'
    }

    # ── Load affinity rules ────────────────────────────────────────────────────
    $ruleSet   = Get-AffinityRuleSet -Path $RulesPath -ClusterName $ClusterName
    $ruleLabel = if ($ruleSet.Count -gt 0) { "$($ruleSet.Count) rule(s)" } else { 'none' }

    Write-Host ("{0} HvDRS starting — Cluster: {1}  Aggression: {2}  Network gate: {3}%  Rules: {4}  Mode: {5}" -f
        (& $ts), $ClusterName, $AggressionLevel, $MaxDestinationNetworkUtil, $ruleLabel, $modeLabel)

    if ($maintenanceActive) {
        Write-Host ("{0} Maintenance lock active ({1}). Metrics will be collected and scored but no migrations will run." -f
            (& $ts), $MaintenanceLockFile) -ForegroundColor Yellow
    }

    # ── Phase 1: Collect cluster snapshot ──────────────────────────────────────
    Write-Host ("{0} Collecting metrics (samples={1}, interval={2}s)..." -f
        (& $ts), $SampleCount, $SampleIntervalSeconds)

    $snapshot = Get-ClusterSnapshot -ClusterName $ClusterName `
                                    -SampleCount $SampleCount `
                                    -SampleIntervalSeconds $SampleIntervalSeconds `
                                    -Verbose:($VerbosePreference -ne 'SilentlyContinue')

    Write-Host ("{0} Snapshot complete: {1} node(s), {2} running VM(s)" -f
        (& $ts), $snapshot.Nodes.Count, $snapshot.VMs.Count)

    # Print current cluster state
    Write-Host ''
    Write-Host '── Node Summary ──────────────────────────────────────────────────────────────'
    $snapshot.Nodes | Format-Table -AutoSize -Property `
        @{ N='Node';     E={ $_.NodeName } },
        @{ N='CPU %';    E={ '{0:N1}' -f $_.CpuUtilization } },
        @{ N='Mem Used'; E={ '{0:N0} MB' -f $_.UsedMemoryMB } },
        @{ N='Mem Free'; E={ '{0:N0} MB' -f $_.AvailableMemoryMB } },
        @{ N='Net %';    E={ '{0:N1}' -f $_.NetworkUtilization } },
        @{ N='VMs';      E={ $_.VMs.Count } }

    # ── Phase 2: Check affinity rule compliance ────────────────────────────────
    if ($ruleSet.Count -gt 0) {
        $violations = @(Test-AffinityCompliance -Snapshot $snapshot -RuleSet $ruleSet)

        if ($violations.Count -gt 0) {
            $hardCount = @($violations | Where-Object { $_.Enforced }).Count
            $softCount = $violations.Count - $hardCount

            Write-Host ('── {0} Rule Violation(s) Detected — {1} hard, {2} soft ──────────────────────────' -f
                $violations.Count, $hardCount, $softCount)

            $violations | Format-Table -AutoSize -Wrap -Property `
                @{ N='Rule';     E={ $_.RuleName } },
                @{ N='Type';     E={ $_.Type } },
                @{ N='Hard';     E={ $_.Enforced } },
                @{ N='VMs';      E={ $_.VMs -join ', ' } },
                @{ N='Detail';   E={ $_.Description } }
        } else {
            Write-Host ("{0} All {1} affinity rule(s) satisfied." -f (& $ts), $ruleSet.Count)
        }
    }

    # ── Phase 3: Score all VMs ─────────────────────────────────────────────────
    $allScores = foreach ($vm in $snapshot.VMs) {
        $hostMetrics = $snapshot.Nodes | Where-Object { $_.NodeName -eq $vm.HostNode }
        if (-not $hostMetrics) { continue }
        Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics `
                            -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight
    }

    Write-Host '── VM Happiness Scores ───────────────────────────────────────────────────────'
    $allScores | Sort-Object HappinessScore | Format-Table -AutoSize -Property `
        @{ N='VM';        E={ $_.VMName } },
        @{ N='Host';      E={ $_.HostNode } },
        @{ N='CPU Happy'; E={ '{0:N1}' -f $_.CpuHappiness } },
        @{ N='Mem Happy'; E={ '{0:N1}' -f $_.MemHappiness } },
        @{ N='Score';     E={ '{0:N1}' -f $_.HappinessScore } },
        @{ N='Status';    E={
            if    ($_.HappinessScore -ge 80) { 'Happy' }
            elseif ($_.HappinessScore -ge 50) { 'Uncomfortable' }
            else                             { 'UNHAPPY' }
        }}

    # ── Phase 4: Find migration candidates ────────────────────────────────────
    $migrations = Find-MigrationCandidates -Snapshot $snapshot `
                                           -AggressionLevel $AggressionLevel `
                                           -CpuWeight $CpuWeight `
                                           -MemoryWeight $MemoryWeight `
                                           -MaxDestinationNetworkUtil $MaxDestinationNetworkUtil `
                                           -DestinationMemoryReserveMB $DestinationMemoryReserveMB `
                                           -RuleSet $ruleSet `
                                           -SoftRuleViolationPenalty $SoftRuleViolationPenalty `
                                           -RuleComplianceBonus $RuleComplianceBonus `
                                           -ClusterName $ClusterName `
                                           -Verbose:($VerbosePreference -ne 'SilentlyContinue')

    if (-not $migrations -or $migrations.Count -eq 0) {
        Write-Host ("{0} Cluster is balanced at aggression level {1}. No migrations needed." -f
            (& $ts), $AggressionLevel)
        return
    }

    Write-Host ''
    Write-Host ('── {0} Migration Recommendation(s) ─────────────────────────────────────────' -f $migrations.Count)
    $migrations | Format-Table -AutoSize -Wrap -Property `
        @{ N='VM';           E={ $_.VMName } },
        @{ N='From';         E={ $_.SourceNode } },
        @{ N='To';           E={ $_.DestinationNode } },
        @{ N='Score Before'; E={ $_.CurrentScore } },
        @{ N='Score After';  E={ $_.ProjectedScore } },
        @{ N='Delta';        E={ '+{0}' -f $_.Improvement } },
        @{ N='CPU Δ';        E={ '{0} → {1}' -f $_.CpuHappinessBefore, $_.CpuHappinessAfter } },
        @{ N='Mem Δ';        E={ '{0} → {1}' -f $_.MemHappinessBefore, $_.MemHappinessAfter } },
        @{ N='Trigger';      E={
            if ($_.ComplianceReason) {
                'Compliance: ' + ($_.ComplianceReason.Substring(0, [Math]::Min(40, $_.ComplianceReason.Length)))
            } else { 'Happiness' }
        }}

    # ── Phase 5: Execute (or preview) migrations ───────────────────────────────
    if (-not $willMigrate) {
        $reason = if ($maintenanceActive) { 'maintenance lock is active' } else { '-RecommendOnly was specified' }
        Write-Host ("{0} Skipping migration execution — {1}." -f (& $ts), $reason)
        Write-Host ''
        Write-Host ("{0} HvDRS pass complete — {1} recommendation(s), no migrations executed." -f
            (& $ts), $migrations.Count)
        return
    }

    $succeeded = 0
    $failed    = 0

    foreach ($migration in $migrations) {
        $trigger = if ($migration.ComplianceReason) { "rule compliance" } else { "happiness" }
        $action  = "Live-migrate '{0}' from '{1}' to '{2}' [{3}; score {4} → {5}]" -f
                   $migration.VMName, $migration.SourceNode, $migration.DestinationNode,
                   $trigger, $migration.CurrentScore, $migration.ProjectedScore

        if (-not $PSCmdlet.ShouldProcess($migration.VMName, $action)) {
            continue  # -WhatIf: ShouldProcess prints the action and skips the body
        }

        Write-Host ("{0} Migrating '{1}': {2} → {3} [{4}] ..." -f
            (& $ts), $migration.VMName, $migration.SourceNode, $migration.DestinationNode, $trigger)

        try {
            Move-ClusterVirtualMachineRole `
                -Cluster       $ClusterName `
                -Name          $migration.VMName `
                -Node          $migration.DestinationNode `
                -MigrationType Live `
                -ErrorAction   Stop | Out-Null

            Write-Host ("{0}   Done. Score {1} → {2} (+{3})" -f
                (& $ts), $migration.CurrentScore, $migration.ProjectedScore, $migration.Improvement)
            $succeeded++
        } catch {
            Write-Warning ("Migration of '{0}' failed: {1}" -f $migration.VMName, $_)
            $failed++
        }
    }

    if ($PSCmdlet.ShouldProcess('summary', 'Report')) {
        Write-Host ''
        Write-Host ("{0} HvDRS pass complete — {1} migrated, {2} failed." -f
            (& $ts), $succeeded, $failed)
    }
}
