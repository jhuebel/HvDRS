function Merge-HvDRSTrendSnapshot {
    <#
    .SYNOPSIS
        Smooths a cluster snapshot's load-sensitive fields over a rolling window of
        recent passes, so a single transient spike doesn't trigger a migration.

    .DESCRIPTION
        Persists a bounded history of prior snapshots' smoothable fields to a JSON
        file at -HistoryPath, appends the current snapshot, trims to -WindowSize
        entries, and returns a new snapshot where Node.CpuUtilization,
        Node.NetworkUtilization, VM.CpuUtilization, and VM.MemoryPressure are
        replaced by their average over the window.

        Capacity fields (TotalMemoryMB, AvailableMemoryMB, LogicalProcessorCount)
        and identity fields are passed through unchanged from the current (real)
        snapshot — they gate destination fit right now, not a multi-pass trend.

        A VM or node absent from some prior entries (added/removed between passes)
        is simply averaged over however many entries it does appear in; there is no
        synthetic zero-fill. A missing or corrupt history file bootstraps to a
        single-entry window (the current snapshot only), mirroring the fail-soft
        load pattern used by Get-AffinityRuleSet.

    .OUTPUTS
        A PSCustomObject shaped exactly like Get-ClusterSnapshot's output
        (ClusterName, Timestamp, Nodes, VMs) so it is a drop-in replacement
        wherever a snapshot is consumed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot,

        [Parameter(Mandatory)]
        [string]$HistoryPath,

        [ValidateRange(1, 10)]
        [int]$WindowSize = 3
    )

    # ── Load prior history (fail-soft: missing/corrupt file => fresh window) ──────
    $history = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (Test-Path -LiteralPath $HistoryPath) {
        try {
            $data = Get-Content -LiteralPath $HistoryPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($entry in @($data.Entries)) { $history.Add($entry) }
        } catch {
            Write-Warning "Could not load HVDRS trend history from '$HistoryPath': $_. Starting a fresh window."
        }
    }

    # ── Append this pass's smoothable fields only ─────────────────────────────────
    $currentEntry = [PSCustomObject]@{
        Nodes = @($Snapshot.Nodes | ForEach-Object {
            [PSCustomObject]@{
                NodeName           = $_.NodeName
                CpuUtilization     = [double]$_.CpuUtilization
                NetworkUtilization = [double]$_.NetworkUtilization
            }
        })
        VMs = @($Snapshot.VMs | ForEach-Object {
            [PSCustomObject]@{
                VMName         = $_.VMName
                CpuUtilization = [double]$_.CpuUtilization
                MemoryPressure = [double]$_.MemoryPressure
            }
        })
    }

    $history.Add($currentEntry)
    while ($history.Count -gt $WindowSize) { $history.RemoveAt(0) }

    # ── Persist the trimmed window ────────────────────────────────────────────────
    $dir = Split-Path -LiteralPath $HistoryPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    [PSCustomObject]@{
        Version = '1.0'
        Entries = $history.ToArray()
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $HistoryPath -Encoding UTF8

    # ── Build the trended (averaged) snapshot ─────────────────────────────────────
    $trendedNodes = foreach ($node in $Snapshot.Nodes) {
        $samples = @($history | ForEach-Object { $_.Nodes | Where-Object { $_.NodeName -eq $node.NodeName } })

        $avgCpu = if ($samples.Count -gt 0) { ($samples | Measure-Object -Property CpuUtilization     -Average).Average } else { $node.CpuUtilization }
        $avgNet = if ($samples.Count -gt 0) { ($samples | Measure-Object -Property NetworkUtilization -Average).Average } else { $node.NetworkUtilization }

        [PSCustomObject]@{
            NodeName              = $node.NodeName
            CpuUtilization        = [Math]::Round($avgCpu, 1)
            TotalMemoryMB         = $node.TotalMemoryMB
            AvailableMemoryMB     = $node.AvailableMemoryMB
            UsedMemoryMB          = $node.UsedMemoryMB
            LogicalProcessorCount = $node.LogicalProcessorCount
            NetworkUtilization    = [Math]::Round($avgNet, 1)
            VMs                   = $node.VMs
        }
    }

    $trendedVMs = foreach ($vm in $Snapshot.VMs) {
        $samples = @($history | ForEach-Object { $_.VMs | Where-Object { $_.VMName -eq $vm.VMName } })

        $avgCpu      = if ($samples.Count -gt 0) { ($samples | Measure-Object -Property CpuUtilization -Average).Average } else { $vm.CpuUtilization }
        $avgPressure = if ($samples.Count -gt 0) { ($samples | Measure-Object -Property MemoryPressure -Average).Average } else { $vm.MemoryPressure }

        [PSCustomObject]@{
            VMName               = $vm.VMName
            VMId                 = $vm.VMId
            CpuUtilization       = [Math]::Round($avgCpu, 1)
            ProcessorCount       = $vm.ProcessorCount
            MemoryAssignedMB     = $vm.MemoryAssignedMB
            MemoryDemandMB       = $vm.MemoryDemandMB
            DynamicMemoryEnabled = $vm.DynamicMemoryEnabled
            MemoryPressure       = [Math]::Round($avgPressure, 1)
            HostNode             = $vm.HostNode
        }
    }

    [PSCustomObject]@{
        ClusterName = $Snapshot.ClusterName
        Timestamp   = $Snapshot.Timestamp
        Nodes       = $trendedNodes
        VMs         = $trendedVMs
    }
}
