$script:HvDRSDefaultAutomationOverridesPath = Join-Path (Get-HvDRSDataRoot) 'HvDRS\automation-overrides.json'

function Set-HvDRSVMAutomationLevel {
    <#
    .SYNOPSIS
        Pins a specific VM to Manual automation, or restores it to FullyAutomated —
        the per-VM automation-level override vSphere DRS exposes, applied to both
        Invoke-HvDRS and Invoke-HvStorageDRS (automation level isn't a compute-vs-
        storage distinction in vSphere either — it's one setting per VM).

    .DESCRIPTION
        FullyAutomated (the default for every VM with no override) means HVDRS may
        execute a migration it recommends for this VM, same as today.

        Manual means HVDRS still scores this VM and includes it in the printed/
        -PassThru recommendation list — it just never calls
        Move-ClusterVirtualMachineRole / Move-VMStorage for it. The recommendation
        is annotated as pinned so an operator knows to review and act on it by hand.

    .PARAMETER ClusterName
        Failover Cluster this override applies to. Defaults to the local cluster if omitted.

    .PARAMETER VMName
        The VM to pin.

    .PARAMETER AutomationLevel
        FullyAutomated or Manual.

    .PARAMETER Reason
        Optional free-text reason stored with the override.

    .PARAMETER OverridesPath
        Path to the JSON override store. Defaults to $env:ProgramData\HvDRS\automation-overrides.json.

    .EXAMPLE
        Set-HvDRSVMAutomationLevel -ClusterName 'PROD-CLUSTER' -VMName 'SQL-PROD-01' -AutomationLevel Manual -Reason 'Change-managed workload'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ClusterName = '',

        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateSet('FullyAutomated', 'Manual')]
        [string]$AutomationLevel,

        [string]$Reason = '',

        [string]$OverridesPath = $script:HvDRSDefaultAutomationOverridesPath
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    if (-not $PSCmdlet.ShouldProcess($VMName, "Set HvDRS automation level to '$AutomationLevel' for cluster '$ClusterName'")) { return }

    $overrides = [System.Collections.Generic.List[PSCustomObject]](Get-HvDRSAutomationOverrideSet -Path $OverridesPath)
    $existing  = $overrides | Where-Object { $_.ClusterName -eq $ClusterName -and $_.VMName -eq $VMName }

    if ($existing) {
        $existing.AutomationLevel = $AutomationLevel
        $existing.Reason          = $Reason
        Write-Host "Automation level for '$VMName' on cluster '$ClusterName' updated to '$AutomationLevel'."
    } else {
        $overrides.Add([PSCustomObject]@{
            ClusterName     = $ClusterName
            VMName          = $VMName
            AutomationLevel = $AutomationLevel
            Reason          = $Reason
            CreatedAt       = (Get-Date -Format 'o')
        })
        Write-Host "Automation level for '$VMName' on cluster '$ClusterName' set to '$AutomationLevel'."
    }

    Save-HvDRSAutomationOverrideSet -Overrides $overrides.ToArray() -Path $OverridesPath
}

function Get-HvDRSVMAutomationLevel {
    <#
    .SYNOPSIS
        Lists per-VM automation-level overrides, with optional filtering.

    .PARAMETER ClusterName
        When specified, returns only overrides for this cluster.

    .PARAMETER VMName
        Return only the override for this VM.

    .PARAMETER OverridesPath
        Path to the JSON override store.
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$VMName,
        [string]$OverridesPath = $script:HvDRSDefaultAutomationOverridesPath
    )

    $overrides = Get-HvDRSAutomationOverrideSet -Path $OverridesPath -ClusterName $ClusterName

    if ($VMName) {
        $matched = @($overrides | Where-Object { $_.VMName -eq $VMName })
        if ($matched.Count -eq 0) { return ,@() }
        return $matched
    }

    # Same leading-comma-on-empty-only protection as Get-AffinityRuleSet — see
    # its comments for why this must not be applied unconditionally.
    if (@($overrides).Count -eq 0) { return ,@() }
    return $overrides
}

function Remove-HvDRSVMAutomationLevel {
    <#
    .SYNOPSIS
        Removes a VM's automation-level override, reverting it to FullyAutomated
        (the default for any VM with no override).

    .PARAMETER ClusterName
        Failover Cluster the override applies to. Defaults to the local cluster if omitted.

    .PARAMETER VMName
        The VM whose override should be removed.

    .PARAMETER OverridesPath
        Path to the JSON override store.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ClusterName = '',

        [Parameter(Mandatory)]
        [string]$VMName,

        [string]$OverridesPath = $script:HvDRSDefaultAutomationOverridesPath
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    $overrides = [System.Collections.Generic.List[PSCustomObject]](Get-HvDRSAutomationOverrideSet -Path $OverridesPath)
    $target    = $overrides | Where-Object { $_.ClusterName -eq $ClusterName -and $_.VMName -eq $VMName }

    if (-not $target) {
        Write-Warning "No automation override found for '$VMName' on cluster '$ClusterName'."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove HvDRS automation-level override')) { return }

    [void]$overrides.Remove($target)
    Save-HvDRSAutomationOverrideSet -Overrides $overrides.ToArray() -Path $OverridesPath
    Write-Host "Automation-level override for '$VMName' removed — it now inherits the default (FullyAutomated)."
}
