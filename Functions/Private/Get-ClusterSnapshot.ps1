function Get-ClusterSnapshot {
    <#
    .SYNOPSIS
        Collects a point-in-time resource snapshot from every Up node in a Failover Cluster.
    .OUTPUTS
        PSCustomObject with Nodes (host metrics) and VMs (per-VM metrics + HostNode annotation).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClusterName,

        [int]$SampleCount = 5,
        [int]$SampleIntervalSeconds = 2
    )

    $nodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop |
             Where-Object { $_.State -eq 'Up' }

    if (-not $nodes) {
        throw "No active nodes found in cluster '$ClusterName'."
    }

    Write-Verbose "Collecting metrics from $($nodes.Count) node(s) in '$ClusterName'..."

    $collectionBlock = {
        param([int]$SampleCount, [int]$SampleInterval)

        # ── CPU (averaged over N samples) ──────────────────────────────────────
        $cpuSamples = Get-Counter '\Processor(_Total)\% Processor Time' `
                          -SampleInterval $SampleInterval -MaxSamples $SampleCount -ErrorAction Stop
        $cpuUtil = ($cpuSamples.CounterSamples |
                    Measure-Object -Property CookedValue -Average).Average

        # ── Memory ────────────────────────────────────────────────────────────
        $os         = Get-CimInstance Win32_OperatingSystem
        $totalMemMB = [Math]::Round($os.TotalVisibleMemorySize / 1KB, 0)  # KB → MB
        $availMemMB = [Math]::Round($os.FreePhysicalMemory      / 1KB, 0)

        $lpCount = (Get-CimInstance Win32_Processor |
                    Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

        # ── Network (2-second delta on all Up physical adapters) ───────────────
        $upAdapters       = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Speed -gt 0 }
        $totalCapacityBps = ($upAdapters | Measure-Object -Property Speed -Sum).Sum

        $snap1 = $upAdapters | ForEach-Object {
            $s = $_ | Get-NetAdapterStatistics
            [PSCustomObject]@{ Name = $_.Name; Bytes = $s.ReceivedBytes + $s.SentBytes }
        }
        $t1 = [DateTime]::UtcNow
        Start-Sleep -Seconds 2
        $snap2 = $upAdapters | ForEach-Object {
            $s = $_ | Get-NetAdapterStatistics
            [PSCustomObject]@{ Name = $_.Name; Bytes = $s.ReceivedBytes + $s.SentBytes }
        }
        $elapsed = ([DateTime]::UtcNow - $t1).TotalSeconds

        $totalBytesPerSec = 0
        foreach ($a1 in $snap1) {
            $a2 = $snap2 | Where-Object { $_.Name -eq $a1.Name }
            if ($a2) { $totalBytesPerSec += ($a2.Bytes - $a1.Bytes) / $elapsed }
        }
        $netUtil = if ($totalCapacityBps -gt 0) {
            [Math]::Min(100, [Math]::Round(($totalBytesPerSec * 8 / $totalCapacityBps) * 100, 1))
        } else { 0 }

        # ── Per-VM metrics ────────────────────────────────────────────────────
        $runningVMs = Get-VM | Where-Object { $_.State -eq 'Running' }

        $vmMetrics = foreach ($vm in $runningVMs) {
            $mem = Get-VMMemory -VMName $vm.Name -ErrorAction SilentlyContinue

            # Dynamic Memory pressure: ~100 = balanced, >100 = starved, <100 = surplus
            $pressure = 100
            if ($mem -and $mem.DynamicMemoryEnabled) {
                try {
                    # Counter instance name must exactly match the VM name
                    $pc = Get-Counter "\Hyper-V Dynamic Memory VM($($vm.Name))\Current Pressure" `
                              -MaxSamples 1 -ErrorAction Stop
                    $pressure = [Math]::Round($pc.CounterSamples[0].CookedValue, 1)
                } catch {
                    $pressure = 100  # Counter unavailable — assume balanced
                }
            }

            [PSCustomObject]@{
                VMName               = $vm.Name
                VMId                 = $vm.Id.ToString()
                CpuUtilization       = $vm.CPUUsage           # 0-100 %
                ProcessorCount       = $vm.ProcessorCount
                MemoryAssignedMB     = [Math]::Round($vm.MemoryAssigned / 1MB, 0)
                MemoryDemandMB       = [Math]::Round($vm.MemoryDemand   / 1MB, 0)
                DynamicMemoryEnabled = ($mem -and $mem.DynamicMemoryEnabled)
                MemoryPressure       = $pressure
            }
        }

        [PSCustomObject]@{
            NodeName              = $env:COMPUTERNAME
            CpuUtilization        = [Math]::Round($cpuUtil, 1)
            TotalMemoryMB         = $totalMemMB
            AvailableMemoryMB     = $availMemMB
            UsedMemoryMB          = $totalMemMB - $availMemMB
            LogicalProcessorCount = $lpCount
            NetworkUtilization    = $netUtil
            VMs                   = $vmMetrics
        }
    }

    $nodeSnapshots = foreach ($node in $nodes) {
        Write-Verbose "  Querying node: $($node.Name)"
        try {
            Invoke-Command -ComputerName $node.Name -ErrorAction Stop `
                           -ArgumentList $SampleCount, $SampleIntervalSeconds `
                           -ScriptBlock $collectionBlock
        } catch {
            Write-Warning "Failed to collect metrics from '$($node.Name)': $_"
            $null
        }
    }

    $nodeSnapshots = @($nodeSnapshots | Where-Object { $_ -ne $null })

    # Flatten VM list with host annotation
    $allVMs = foreach ($snap in $nodeSnapshots) {
        foreach ($vm in $snap.VMs) {
            $vm | Add-Member -NotePropertyName 'HostNode' -NotePropertyValue $snap.NodeName -Force -PassThru
        }
    }

    [PSCustomObject]@{
        ClusterName = $ClusterName
        Timestamp   = Get-Date
        Nodes       = $nodeSnapshots
        VMs         = @($allVMs)
    }
}
