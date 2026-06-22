function Get-HvDRSCluster {
    <#
    .SYNOPSIS
        Discovers the nodes, VMs, and Cluster Shared Volumes in a Hyper-V Failover Cluster.

    .DESCRIPTION
        A lightweight, read-only inventory cmdlet. Unlike Invoke-HvDRS / Invoke-HvStorageDRS,
        it collects no CPU, memory, network, or storage I/O performance counters — it only
        enumerates what currently exists in the cluster — so it returns quickly and never
        proposes or executes migrations.

        Useful for ad-hoc exploration (which VMs are on which host, which CSVs exist and
        how full they are) or as a starting point for scripting against cluster inventory
        without running a full DRS pass.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster if omitted.

    .EXAMPLE
        Get-HvDRSCluster -ClusterName 'PROD-CLUSTER'

    .EXAMPLE
        # VMs currently running on a specific host
        (Get-HvDRSCluster).VMs | Where-Object { $_.HostNode -eq 'HV-NODE1' }

    .EXAMPLE
        # CSVs sorted by free space
        (Get-HvDRSCluster).CSVs | Sort-Object FreeGB
    #>
    [CmdletBinding()]
    param(
        [string] $ClusterName
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    Get-ClusterInventory -ClusterName $ClusterName -Verbose:($VerbosePreference -ne 'SilentlyContinue')
}
