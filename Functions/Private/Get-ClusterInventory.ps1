function Get-ClusterInventory {
    <#
    .SYNOPSIS
        Performs lightweight discovery of nodes, VMs, and Cluster Shared Volumes in a
        Failover Cluster.

    .DESCRIPTION
        Unlike Get-ClusterSnapshot / Get-StorageSnapshot, this collects no performance
        counters (CPU, memory, network, I/O latency) — it only enumerates what exists,
        so it returns quickly and is safe to call at any time.

    .OUTPUTS
        PSCustomObject:
          ClusterName — string
          Timestamp   — DateTime
          Nodes       — array of PSCustomObject (NodeName, State)
          VMs         — array of PSCustomObject (VMName, VMId, HostNode, State,
                        ProcessorCount, MemoryAssignedMB)
          CSVs        — array of PSCustomObject (Name, Path, OwnerNode, TotalGB, FreeGB)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ClusterName
    )

    Write-Verbose "[ClusterInventory] Enumerating nodes on '$ClusterName'..."
    $clusterNodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop

    $nodeList = foreach ($node in $clusterNodes) {
        [PSCustomObject]@{
            NodeName = $node.Name
            State    = $node.State.ToString()
        }
    }

    $upNodes = @($clusterNodes | Where-Object { $_.State -eq 'Up' } | Select-Object -ExpandProperty Name)

    Write-Verbose "[ClusterInventory] Enumerating VMs across $($upNodes.Count) up node(s)..."
    $vmList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($node in $upNodes) {
        try {
            Get-VM -ComputerName $node -ErrorAction Stop | ForEach-Object {
                $vmList.Add([PSCustomObject]@{
                    VMName           = $_.Name
                    VMId             = $_.Id.ToString()
                    HostNode         = $node
                    State            = $_.State.ToString()
                    ProcessorCount   = $_.ProcessorCount
                    MemoryAssignedMB = [Math]::Round($_.MemoryAssigned / 1MB, 0)
                })
            }
        } catch {
            Write-Warning "[ClusterInventory] Could not enumerate VMs on '$node': $_"
        }
    }

    Write-Verbose "[ClusterInventory] Enumerating Cluster Shared Volumes..."
    $csvList = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction Stop | ForEach-Object {
            $part    = $_.SharedVolumeInfo.Partition
            $totalGB = [Math]::Round($part.Size      / 1GB, 2)
            $freeGB  = [Math]::Round($part.FreeSpace / 1GB, 2)
            $csvList.Add([PSCustomObject]@{
                Name      = $_.Name
                Path      = $_.SharedVolumeInfo.FriendlyVolumeName
                OwnerNode = if ($_.OwnerNode) { $_.OwnerNode.Name } else { $null }
                TotalGB   = $totalGB
                FreeGB    = $freeGB
            })
        }
    } catch {
        Write-Warning "[ClusterInventory] Could not enumerate Cluster Shared Volumes: $_"
    }

    [PSCustomObject]@{
        ClusterName = $ClusterName
        Timestamp   = Get-Date
        Nodes       = @($nodeList)
        VMs         = @($vmList.ToArray())
        CSVs        = @($csvList.ToArray())
    }
}
