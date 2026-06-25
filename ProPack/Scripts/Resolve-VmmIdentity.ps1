function Test-HvDrsHostNameMatch {
    <#
    .SYNOPSIS
        Compares a VMM host name against a Failover Cluster node name, tolerating
        short-name vs. FQDN mismatches (e.g. 'HOST-A' vs 'HOST-A.contoso.com').
    #>
    [CmdletBinding()]
    param(
        [string]$CandidateName,
        [string]$TargetName
    )

    if (-not $CandidateName -or -not $TargetName) { return $false }
    if ($CandidateName -ieq $TargetName) { return $true }

    $candidateShort = $CandidateName.Split('.')[0]
    $targetShort    = $TargetName.Split('.')[0]
    return ($candidateShort -ieq $targetShort)
}

function Resolve-VmmIdentity {
    <#
    .SYNOPSIS
        Resolves a Hyper-V VM GUID and a Failover Cluster destination node name to
        the VMM objects (SCVirtualMachine, SCVMHost) needed to act on an HVDRS
        recommendation inside VMM.

    .DESCRIPTION
        Joins on VMId (the Hyper-V VM GUID), never on VM display name — VMM
        environments commonly have duplicate display names across clouds/host
        groups, so name-based matching is unreliable. Host matching tolerates a
        short-name vs. FQDN mismatch between the cluster node name HVDRS reports
        and the host name VMM uses.

        Designed to fail soft: if either the VM or the destination host cannot be
        resolved to a VMM object, returns Resolved = $false with a FailureReason
        instead of throwing — callers should skip emitting a PRO Tip for that
        recommendation and let the next probe cycle retry, rather than surface a
        PRO Tip referencing an object VMM can't act on.

    .OUTPUTS
        PSCustomObject: Resolved, VirtualMachine, VMHost, FailureReason
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMId,

        [Parameter(Mandatory)]
        [string]$DestinationNodeName,

        [string]$VMMServer
    )

    $result = [PSCustomObject]@{
        Resolved       = $false
        VirtualMachine = $null
        VMHost         = $null
        FailureReason  = $null
    }

    $getVmParams = @{ All = $true; ErrorAction = 'Stop' }
    if ($VMMServer) { $getVmParams['VMMServer'] = $VMMServer }

    try {
        $vmmVMs = @(Get-SCVirtualMachine @getVmParams)
    } catch {
        $result.FailureReason = "Failed to query Get-SCVirtualMachine: $_"
        return $result
    }

    $vm = $vmmVMs | Where-Object { $_.VMId -and ($_.VMId.ToString() -ieq $VMId) } | Select-Object -First 1
    if (-not $vm) {
        $result.FailureReason = "No VMM-managed virtual machine found with VMId '$VMId'"
        return $result
    }

    $getHostParams = @{ ErrorAction = 'Stop' }
    if ($VMMServer) { $getHostParams['VMMServer'] = $VMMServer }

    try {
        $vmmHosts = @(Get-SCVMHost @getHostParams)
    } catch {
        $result.FailureReason = "Failed to query Get-SCVMHost: $_"
        return $result
    }

    $matchedHost = $vmmHosts | Where-Object { Test-HvDrsHostNameMatch -CandidateName $_.Name -TargetName $DestinationNodeName } |
        Select-Object -First 1
    if (-not $matchedHost) {
        $result.FailureReason = "No VMM-managed host found matching destination node '$DestinationNodeName'"
        return $result
    }

    $result.Resolved       = $true
    $result.VirtualMachine = $vm
    $result.VMHost         = $matchedHost
    return $result
}
