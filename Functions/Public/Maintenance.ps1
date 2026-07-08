function Enable-HvDRSMaintenance {
    <#
    .SYNOPSIS
        Drops a maintenance lock file that causes HvDRS to skip all live migrations.

    .DESCRIPTION
        Creates the maintenance lock file checked by Invoke-HvDRS at the start of each pass.
        While the file exists, HvDRS will still collect metrics and score VMs but will not
        execute or propose any live migrations.

        Remove the lock with Disable-HvDRSMaintenance when the maintenance window ends.

    .PARAMETER Reason
        Optional free-text reason stored inside the lock file (shown in HvDRS output).

    .PARAMETER LockFile
        Path to the lock file. Must match the -MaintenanceLockFile path used by Invoke-HvDRS.
        Default: $env:ProgramData\HvDRS\maintenance.lock

    .EXAMPLE
        Enable-HvDRSMaintenance -Reason 'Patch Tuesday patching window'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Reason = 'Maintenance window',
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (-not $PSCmdlet.ShouldProcess($LockFile, 'Create maintenance lock file')) { return }

    $dir = Split-Path $LockFile
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $content = "{0} — enabled {1}" -f $Reason, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Set-Content -LiteralPath $LockFile -Value $content -Encoding UTF8

    Write-Host "HvDRS maintenance mode ENABLED."
    Write-Host "  Lock file : $LockFile"
    Write-Host "  Reason    : $Reason"
    Write-Host "  Run Disable-HvDRSMaintenance to resume automatic migrations."
}

function Disable-HvDRSMaintenance {
    <#
    .SYNOPSIS
        Removes the HvDRS maintenance lock file, re-enabling automatic live migrations.

    .PARAMETER LockFile
        Path to the lock file. Must match the -MaintenanceLockFile path used by Invoke-HvDRS.
        Default: $env:ProgramData\HvDRS\maintenance.lock

    .EXAMPLE
        Disable-HvDRSMaintenance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (-not (Test-Path -LiteralPath $LockFile)) {
        Write-Warning "Maintenance lock file not found at '$LockFile'. HvDRS is already active."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($LockFile, 'Remove maintenance lock file')) { return }

    Remove-Item -LiteralPath $LockFile -Force
    Write-Host "HvDRS maintenance mode DISABLED. Automatic migrations will resume on the next pass."
}

function Get-HvDRSMaintenanceStatus {
    <#
    .SYNOPSIS
        Reports whether HvDRS maintenance mode is currently active.

    .PARAMETER LockFile
        Path to the lock file.
        Default: $env:ProgramData\HvDRS\maintenance.lock
    #>
    [CmdletBinding()]
    param(
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (Test-Path -LiteralPath $LockFile) {
        $content = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            MaintenanceActive = $true
            LockFile          = $LockFile
            Reason            = $content
        }
    } else {
        [PSCustomObject]@{
            MaintenanceActive = $false
            LockFile          = $LockFile
            Reason            = $null
        }
    }
}

function Enter-HvDRSNodeMaintenance {
    <#
    .SYNOPSIS
        Evacuates every running VM off a cluster node using HVDRS's happiness-aware
        destination selection, then pauses the node so it stops receiving new
        cluster role placements — a Hyper-V-cluster analog of vSphere's "Enter
        Maintenance Mode".

    .DESCRIPTION
        Unlike Suspend-ClusterNode -Drain, which lets the Failover Cluster's own
        placement logic choose destinations, this function scores every candidate
        node with the same VM Happiness model Invoke-HvDRS uses (Network-Aware NIC
        gate, post-migration memory reserve, possible-owner constraints, and
        hard/soft affinity-rule impact — see Find-EvacuationDestination) and
        live-migrates each VM to the best-scoring valid destination via
        Move-ClusterVirtualMachineRole.

        If any VM cannot be evacuated (e.g. a hard host-affinity rule leaves no
        valid destination, or the migration itself fails), the node is NOT paused
        and the failure is reported — pausing a node that still has unmovable VMs
        on it would strand them there indefinitely.

        Use -WhatIf to preview the full evacuation + pause plan without moving
        anything or pausing the node.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER NodeName
        The cluster node to drain and pause.

    .PARAMETER RulesPath
        Path to the JSON affinity rule store. Same default/semantics as Invoke-HvDRS.

    .PARAMETER CpuWeight
        Relative weight of CPU happiness when scoring candidate destinations (default: 0.5).

    .PARAMETER MemoryWeight
        Relative weight of memory happiness when scoring candidate destinations (default: 0.5).

    .PARAMETER MaxDestinationNetworkUtil
        Network-Aware DRS gate: destination hosts at or above this NIC utilization
        percentage are excluded (default: 70%). Same semantics as Invoke-HvDRS.

    .PARAMETER DestinationMemoryReserveMB
        Minimum free memory (MB) that must remain on the destination after the VM
        lands (default: 512 MB).

    .PARAMETER SoftRuleViolationPenalty
        Score penalty applied when a candidate destination would break a soft
        affinity rule (default: 25).

    .PARAMETER RuleComplianceBonus
        Score bonus applied when a candidate destination would fix an existing
        soft rule violation (default: 25).

    .PARAMETER SampleCount
        CPU counter samples to average per node when snapshotting (default: 5).

    .PARAMETER SampleIntervalSeconds
        Seconds between CPU counter samples (default: 2).

    .EXAMPLE
        # Preview the evacuation plan without moving anything
        Enter-HvDRSNodeMaintenance -ClusterName 'PROD-CLUSTER' -NodeName 'HV-NODE3' -WhatIf

    .EXAMPLE
        # Drain and pause the node
        Enter-HvDRSNodeMaintenance -ClusterName 'PROD-CLUSTER' -NodeName 'HV-NODE3'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$ClusterName,

        [Parameter(Mandatory)]
        [string]$NodeName,

        [string]$RulesPath = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json'),

        [ValidateRange(0.0, 1.0)]
        [float]$CpuWeight = 0.5,

        [ValidateRange(0.0, 1.0)]
        [float]$MemoryWeight = 0.5,

        [ValidateRange(0.0, 100.0)]
        [float]$MaxDestinationNetworkUtil = 70.0,

        [int]$DestinationMemoryReserveMB = 512,

        [ValidateRange(0.0, 100.0)]
        [float]$SoftRuleViolationPenalty = 25.0,

        [ValidateRange(0.0, 100.0)]
        [float]$RuleComplianceBonus = 25.0,

        [int]$SampleCount = 5,

        [int]$SampleIntervalSeconds = 2
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    Write-Host "Collecting cluster snapshot..."
    $snapshot = Get-ClusterSnapshot -ClusterName $ClusterName -SampleCount $SampleCount -SampleIntervalSeconds $SampleIntervalSeconds
    $ruleSet  = Get-AffinityRuleSet -Path $RulesPath -ClusterName $ClusterName

    $vmsToEvacuate = @($snapshot.VMs | Where-Object { $_.HostNode -eq $NodeName })

    if ($vmsToEvacuate.Count -eq 0) {
        Write-Host "No running VMs found on '$NodeName'."
    } else {
        Write-Host "Evacuating $($vmsToEvacuate.Count) VM(s) from '$NodeName'..."
    }

    $results   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allPlaced = $true

    foreach ($vm in $vmsToEvacuate) {
        $dest = Find-EvacuationDestination -VM $vm -Snapshot $snapshot -ExcludeNode $NodeName `
                                           -RuleSet $ruleSet -CpuWeight $CpuWeight -MemoryWeight $MemoryWeight `
                                           -MaxDestinationNetworkUtil $MaxDestinationNetworkUtil `
                                           -DestinationMemoryReserveMB $DestinationMemoryReserveMB `
                                           -SoftRuleViolationPenalty $SoftRuleViolationPenalty `
                                           -RuleComplianceBonus $RuleComplianceBonus `
                                           -ClusterName $ClusterName

        if (-not $dest) {
            $allPlaced = $false
            Write-Warning "No valid destination found for '$($vm.VMName)' — it will remain on '$NodeName'."
            $results.Add([PSCustomObject]@{
                VMName          = $vm.VMName
                DestinationNode = $null
                Succeeded       = $false
                Message         = 'No valid destination found'
            })
            continue
        }

        $action = "Live-migrate '{0}' from '{1}' to '{2}' [projected score {3}]" -f
                  $vm.VMName, $NodeName, $dest.DestinationNode, $dest.ProjectedScore

        if (-not $PSCmdlet.ShouldProcess($vm.VMName, $action)) {
            $results.Add([PSCustomObject]@{
                VMName          = $vm.VMName
                DestinationNode = $dest.DestinationNode
                Succeeded       = $false
                Message         = 'Skipped (-WhatIf)'
            })
            continue
        }

        try {
            Move-ClusterVirtualMachineRole -Cluster $ClusterName -Name $vm.VMName `
                                           -Node $dest.DestinationNode -MigrationType Live -ErrorAction Stop | Out-Null
            Write-Host "  Migrated '$($vm.VMName)' -> '$($dest.DestinationNode)' (score $($dest.ProjectedScore))"
            $results.Add([PSCustomObject]@{
                VMName          = $vm.VMName
                DestinationNode = $dest.DestinationNode
                Succeeded       = $true
                Message         = 'Migrated'
            })
        } catch {
            $allPlaced = $false
            Write-Warning "Migration of '$($vm.VMName)' to '$($dest.DestinationNode)' failed: $_"
            $results.Add([PSCustomObject]@{
                VMName          = $vm.VMName
                DestinationNode = $dest.DestinationNode
                Succeeded       = $false
                Message         = "Migration failed: $_"
            })
        }
    }

    $nodePaused = $false
    if (-not $allPlaced) {
        Write-Warning "Not all VMs could be evacuated from '$NodeName' — node will NOT be paused."
    } elseif ($PSCmdlet.ShouldProcess($NodeName, 'Pause cluster node (Suspend-ClusterNode)')) {
        try {
            Suspend-ClusterNode -Cluster $ClusterName -Name $NodeName -ErrorAction Stop | Out-Null
            Write-Host "Node '$NodeName' paused."
            $nodePaused = $true
        } catch {
            Write-Warning "Failed to pause node '$NodeName': $_"
        }
    }

    [PSCustomObject]@{
        ClusterName = $ClusterName
        NodeName    = $NodeName
        Evacuated   = $results.ToArray()
        AllPlaced   = $allPlaced
        NodePaused  = $nodePaused
    }
}

function Exit-HvDRSNodeMaintenance {
    <#
    .SYNOPSIS
        Resumes a cluster node previously paused by Enter-HvDRSNodeMaintenance (or
        any other Suspend-ClusterNode caller), allowing it to receive new cluster
        role placements again.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER NodeName
        The cluster node to resume.

    .EXAMPLE
        Exit-HvDRSNodeMaintenance -ClusterName 'PROD-CLUSTER' -NodeName 'HV-NODE3'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$ClusterName,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    if (-not $PSCmdlet.ShouldProcess($NodeName, 'Resume cluster node (Resume-ClusterNode)')) { return }

    Resume-ClusterNode -Cluster $ClusterName -Name $NodeName -ErrorAction Stop | Out-Null
    Write-Host "Node '$NodeName' resumed."
}

function Get-HvDRSNodeMaintenanceStatus {
    <#
    .SYNOPSIS
        Reports the paused/up state of one or all nodes in a Failover Cluster —
        read-only, no snapshot collection or migrations.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .PARAMETER NodeName
        Report only this node. Omit to report all nodes.

    .EXAMPLE
        Get-HvDRSNodeMaintenanceStatus -ClusterName 'PROD-CLUSTER'
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName,
        [string]$NodeName
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    $nodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop
    if ($NodeName) { $nodes = @($nodes | Where-Object { $_.Name -eq $NodeName }) }

    foreach ($node in $nodes) {
        [PSCustomObject]@{
            ClusterName = $ClusterName
            NodeName    = $node.Name
            State       = $node.State.ToString()
            Paused      = ($node.State.ToString() -eq 'Paused')
        }
    }
}
