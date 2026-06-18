function Get-StorageSnapshot {
    <#
    .SYNOPSIS
        Collects a point-in-time storage snapshot from a Failover Cluster:
        space and I/O metrics for every Cluster Shared Volume, plus VHD placement
        for every running VM.

    .DESCRIPTION
        Space metrics (TotalGB, FreeGB, UsedGB, SpaceUsedPct) are always collected
        from Get-ClusterSharedVolume.

        I/O metrics (ReadIOPS, WriteIOPS, LatencyMs) are collected on a best-effort
        basis using performance counters:
          • IOPS via \Cluster Disk Counters(*)\Disk Reads/sec and Disk Writes/sec
            queried from the first available cluster node.
          • Latency via \LogicalDisk(*)\Avg. Disk sec/Transfer queried on each
            CSV's owner node. CSVs may not appear as LogicalDisk instances on all
            Windows versions; failures are logged as verbose and the fields stay null.

        When I/O metrics are unavailable, Measure-CsvHappiness automatically
        normalises to a space-only score.

    .OUTPUTS
        PSCustomObject:
          ClusterName  — string
          Timestamp    — DateTime
          CSVs         — array of CSV metric objects (Name, Path, OwnerNode, TotalGB,
                         FreeGB, UsedGB, SpaceUsedPct, ReadIOPS, WriteIOPS, LatencyMs)
          VMs          — array of VM storage objects (VMName, VMId, HostNode,
                         PrimaryCSV [path], TotalVhdGB, VHDs)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ClusterName,

        [int] $SampleCount           = 3,
        [int] $SampleIntervalSeconds = 5
    )

    # ── Cluster Shared Volumes ─────────────────────────────────────────────────
    Write-Verbose "[StorageSnapshot] Enumerating CSVs on '$ClusterName'..."
    $clusterCsvs = Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction Stop
    $upNodes     = @(Get-ClusterNode -Cluster $ClusterName |
                     Where-Object { $_.State -eq 'Up' } |
                     Select-Object -ExpandProperty Name)

    if (-not $clusterCsvs -or $clusterCsvs.Count -eq 0) {
        Write-Warning "No Cluster Shared Volumes found on '$ClusterName'."
        return [PSCustomObject]@{ ClusterName=$ClusterName; Timestamp=Get-Date; CSVs=@(); VMs=@() }
    }

    # Build CSV list with space metrics (always available)
    $csvList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($csv in $clusterCsvs) {
        $part    = $csv.SharedVolumeInfo.Partition
        $totalGB = [Math]::Round($part.Size      / 1GB, 2)
        $freeGB  = [Math]::Round($part.FreeSpace / 1GB, 2)
        $usedGB  = [Math]::Round($totalGB - $freeGB, 2)
        $csvList.Add([PSCustomObject]@{
            Name         = $csv.Name
            Path         = $csv.SharedVolumeInfo.FriendlyVolumeName
            OwnerNode    = if ($csv.OwnerNode) { $csv.OwnerNode.Name } else { $null }
            TotalGB      = $totalGB
            FreeGB       = $freeGB
            UsedGB       = $usedGB
            SpaceUsedPct = if ($totalGB -gt 0) { [Math]::Round(($usedGB / $totalGB) * 100.0, 1) } else { 0.0 }
            ReadIOPS     = $null
            WriteIOPS    = $null
            LatencyMs    = $null
        })
    }

    # ── I/O counters — IOPS via Cluster Disk Counters ─────────────────────────
    if ($SampleCount -gt 0 -and $upNodes.Count -gt 0) {
        $coordinator = $upNodes[0]
        Write-Verbose "[StorageSnapshot] Collecting IOPS counters via '$coordinator'..."
        try {
            $instances = (Get-Counter -ComputerName $coordinator `
                                      -ListSet 'Cluster Disk Counters' `
                                      -ErrorAction Stop).PathsWithInstances |
                         Where-Object { $_ -match 'Disk Reads/sec' }

            foreach ($csv in $csvList) {
                $match = $instances | Where-Object { $_ -like "*($($csv.Name))*" } | Select-Object -First 1
                if (-not $match) { continue }

                $inst = [regex]::Match($match, '\((.+?)\)').Groups[1].Value
                $samples = Get-Counter -ComputerName $coordinator -Counter @(
                    "\Cluster Disk Counters($inst)\Disk Reads/sec"
                    "\Cluster Disk Counters($inst)\Disk Writes/sec"
                ) -SampleInterval $SampleIntervalSeconds -MaxSamples $SampleCount -ErrorAction Stop

                $all = $samples.CounterSamples
                $csv.ReadIOPS  = [Math]::Round(($all | Where-Object { $_.Path -match 'Reads'  } | Measure-Object CookedValue -Average).Average, 1)
                $csv.WriteIOPS = [Math]::Round(($all | Where-Object { $_.Path -match 'Writes' } | Measure-Object CookedValue -Average).Average, 1)
                Write-Verbose "[StorageSnapshot]   $($csv.Name): $($csv.ReadIOPS) read IOPS, $($csv.WriteIOPS) write IOPS"
            }
        } catch {
            Write-Verbose "[StorageSnapshot] Cluster Disk Counters unavailable: $_"
        }

        # Latency via LogicalDisk on each CSV's owner node (best-effort)
        foreach ($csv in $csvList) {
            if (-not $csv.OwnerNode) { continue }
            Write-Verbose "[StorageSnapshot] Collecting latency for '$($csv.Name)' on '$($csv.OwnerNode)'..."
            try {
                $latMs = Invoke-Command -ComputerName $csv.OwnerNode -ErrorAction Stop -ScriptBlock {
                    param($csvPath, $cnt, $interval)
                    $paths = (Get-Counter -ListSet 'LogicalDisk').PathsWithInstances |
                             Where-Object { $_ -match 'Avg\. Disk sec/Transfer' }
                    $leafName = Split-Path -Leaf $csvPath
                    $line = $paths | Where-Object { $_ -like "*$leafName*" -or $_ -like "*$csvPath*" } |
                            Select-Object -First 1
                    if (-not $line) { return $null }
                    $inst = [regex]::Match($line, '\((.+?)\)').Groups[1].Value
                    $raw  = Get-Counter "\LogicalDisk($inst)\Avg. Disk sec/Transfer" `
                                        -SampleInterval $interval -MaxSamples $cnt -ErrorAction Stop
                    [Math]::Round(($raw.CounterSamples | Measure-Object CookedValue -Average).Average * 1000, 2)
                } -ArgumentList $csv.Path, $SampleCount, $SampleIntervalSeconds

                if ($null -ne $latMs) {
                    $csv.LatencyMs = $latMs
                    Write-Verbose "[StorageSnapshot]   $($csv.Name): $($csv.LatencyMs) ms latency"
                }
            } catch {
                Write-Verbose "[StorageSnapshot] LogicalDisk latency unavailable for '$($csv.Name)': $_"
            }
        }
    }

    # ── VM storage placement ───────────────────────────────────────────────────
    Write-Verbose "[StorageSnapshot] Enumerating running VM storage across $($upNodes.Count) node(s)..."
    $vmStorage = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($node in $upNodes) {
        $vms = try {
            Get-VM -ComputerName $node -ErrorAction Stop | Where-Object { $_.State -eq 'Running' }
        } catch {
            Write-Warning "[StorageSnapshot] Could not enumerate VMs on '$node': $_"
            continue
        }

        foreach ($vm in $vms) {
            try {
                $drives     = Get-VMHardDiskDrive -VMName $vm.Name -ComputerName $node -ErrorAction Stop
                $vhdDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
                $totalVhdGB = 0.0

                foreach ($drive in $drives) {
                    $sizeGB = try {
                        [Math]::Round((Get-VHD -Path $drive.Path -ComputerName $node -ErrorAction Stop).Size / 1GB, 2)
                    } catch { 0.0 }

                    $csvOwner = $csvList | Where-Object { $drive.Path -like "$($_.Path)*" } | Select-Object -First 1
                    $vhdDetails.Add([PSCustomObject]@{
                        Path   = $drive.Path
                        SizeGB = $sizeGB
                        CSV    = $csvOwner.Path
                    })
                    $totalVhdGB += $sizeGB
                }

                # Primary CSV = the CSV hosting the most VHD data for this VM
                $primaryCSV = $vhdDetails |
                    Where-Object { $_.CSV } |
                    Group-Object CSV |
                    Sort-Object { ($_.Group | Measure-Object SizeGB -Sum).Sum } -Descending |
                    Select-Object -First 1 -ExpandProperty Name

                if (-not $primaryCSV) { continue }   # no VHDs on any CSV (pass-through, physical)

                $vmStorage.Add([PSCustomObject]@{
                    VMName     = $vm.Name
                    VMId       = $vm.Id.ToString()
                    HostNode   = $node
                    PrimaryCSV = $primaryCSV
                    TotalVhdGB = [Math]::Round($totalVhdGB, 2)
                    VHDs       = $vhdDetails.ToArray()
                })
            } catch {
                Write-Warning "[StorageSnapshot] Could not collect storage info for '$($vm.Name)': $_"
            }
        }
    }

    Write-Verbose "[StorageSnapshot] Done: $($csvList.Count) CSV(s), $($vmStorage.Count) VM(s) with CSV storage."

    [PSCustomObject]@{
        ClusterName = $ClusterName
        Timestamp   = Get-Date
        CSVs        = $csvList.ToArray()
        VMs         = $vmStorage.ToArray()
    }
}
