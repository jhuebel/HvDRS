function Resolve-VmmStorageIdentity {
    <#
    .SYNOPSIS
        Resolves a Hyper-V VM GUID and a destination CSV name to the VMM objects
        (SCVirtualMachine, storage volume) needed to act on an HVDRS storage
        recommendation inside VMM.

    .DESCRIPTION
        Joins the VM on VMId exactly like Resolve-VmmIdentity (never on display
        name — see that function's notes on why). The destination CSV is matched
        against VMM's storage volume inventory by name/label.

        CONFIRM: the exact VMM cmdlet and property names for storage volume
        inventory are VMM-version-dependent — the same category of ambiguity the
        compute-side ManagementPack XML already flags with CONFIRM comments for
        the host-cluster class and PRO Tip write-action type. This implementation
        targets Get-SCStorageVolume, matching a CSV's friendly name (e.g.
        'Volume1') against the volume's Name or Label property; confirm this
        mapping against your installed VMM version before relying on it, and
        adjust the match below if your environment exposes CSVs differently.

        Designed to fail soft: if either the VM or the destination volume cannot
        be resolved, returns Resolved = $false with a FailureReason instead of
        throwing — callers should skip emitting a PRO Tip for that recommendation
        and let the next probe cycle retry.

    .OUTPUTS
        PSCustomObject: Resolved, VirtualMachine, StorageVolume, FailureReason
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMId,

        [Parameter(Mandatory)]
        [string]$DestinationCsvName,

        [string]$VMMServer
    )

    $result = [PSCustomObject]@{
        Resolved       = $false
        VirtualMachine = $null
        StorageVolume  = $null
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

    $getVolParams = @{ ErrorAction = 'Stop' }
    if ($VMMServer) { $getVolParams['VMMServer'] = $VMMServer }

    try {
        $volumes = @(Get-SCStorageVolume @getVolParams)
    } catch {
        $result.FailureReason = "Failed to query Get-SCStorageVolume: $_"
        return $result
    }

    $matchedVolume = $volumes | Where-Object { $_.Name -ieq $DestinationCsvName -or $_.Label -ieq $DestinationCsvName } |
        Select-Object -First 1
    if (-not $matchedVolume) {
        $result.FailureReason = "No VMM-managed storage volume found matching destination CSV '$DestinationCsvName'"
        return $result
    }

    $result.Resolved       = $true
    $result.VirtualMachine = $vm
    $result.StorageVolume  = $matchedVolume
    return $result
}
