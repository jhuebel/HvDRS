$script:HvDRSValidGroupTypes   = @('Vm', 'Host', 'Csv')
$script:HvDRSDefaultGroupsPath = Join-Path (Get-HvDRSDataRoot) 'HvDRS\groups.json'

function Add-HvDRSGroup {
    <#
    .SYNOPSIS
        Defines a reusable named group of VMs, hosts, or CSVs that affinity rules
        can reference via -VMGroups / -HostGroups / -CSVGroups instead of listing
        members directly — the same "VM/Host DRS Group" concept vSphere uses.

    .DESCRIPTION
        Group membership is resolved dynamically by Get-AffinityRuleSet every time
        rules are loaded — editing a group's members with Set-HvDRSGroup takes
        effect on the next read of any rule that references it, with no need to
        edit or re-save the rules themselves.

    .PARAMETER ClusterName
        Failover Cluster this group applies to. Defaults to the local cluster if omitted.

    .PARAMETER Name
        Human-readable name for the group. Must be unique within a cluster.

    .PARAMETER Type
        Vm   — a group of VM names, referenced via -VMGroups on an affinity rule.
        Host — a group of cluster node names, referenced via -HostGroups.
        Csv  — a group of Cluster Shared Volume names, referenced via -CSVGroups.

    .PARAMETER Members
        Names of the VMs, hosts, or CSVs in this group.

    .PARAMETER Description
        Optional free-text description stored with the group.

    .PARAMETER GroupsPath
        Path to the JSON group store. Defaults to $env:ProgramData\HvDRS\groups.json.

    .EXAMPLE
        Add-HvDRSGroup -ClusterName 'PROD-CLUSTER' -Name 'SQL VMs' -Type Vm -Members 'SQL-PROD-01','SQL-PROD-02'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ClusterName = '',

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Vm', 'Host', 'Csv')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string[]]$Members,

        [string]$Description = '',

        [string]$GroupsPath = $script:HvDRSDefaultGroupsPath
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Add HvDRS $Type group for cluster '$ClusterName'")) { return }

    $groups = [System.Collections.Generic.List[PSCustomObject]](Get-HvDRSGroupSet -Path $GroupsPath)

    if ($groups | Where-Object { $_.ClusterName -eq $ClusterName -and $_.Name -eq $Name }) {
        Write-Warning "A group named '$Name' already exists for cluster '$ClusterName'. Use Set-HvDRSGroup to modify it."
        return
    }

    $group = [PSCustomObject]@{
        GroupId     = [System.Guid]::NewGuid().ToString()
        Name        = $Name
        ClusterName = $ClusterName
        Type        = $Type
        Members     = @($Members)
        Description = $Description
        CreatedAt   = (Get-Date -Format 'o')
    }

    $groups.Add($group)
    Save-HvDRSGroupSet -Groups $groups.ToArray() -Path $GroupsPath

    Write-Host "Group '$Name' added for cluster '$ClusterName' (ID: $($group.GroupId))."
    return $group
}

function Get-HvDRSGroup {
    <#
    .SYNOPSIS
        Lists HVDRS groups, with optional filtering.

    .PARAMETER ClusterName
        When specified, returns only groups belonging to this cluster.

    .PARAMETER GroupId
        Return the group with this specific ID.

    .PARAMETER Name
        Filter by name. Supports wildcards (e.g. 'SQL*').

    .PARAMETER Type
        Filter by group type (Vm, Host, Csv).

    .PARAMETER GroupsPath
        Path to the JSON group store.
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    param(
        [string] $ClusterName = '',
        [Parameter(ParameterSetName = 'ById',   Mandatory)] [string] $GroupId,
        [Parameter(ParameterSetName = 'ByName')]             [string] $Name,
        [Parameter(ParameterSetName = 'ByType')]
        [ValidateSet('Vm', 'Host', 'Csv')]
        [string] $Type,
        [string] $GroupsPath = $script:HvDRSDefaultGroupsPath
    )

    $groups = Get-HvDRSGroupSet -Path $GroupsPath -ClusterName $ClusterName

    # See Get-HvDRSAffinityRule.ps1 for why each branch assigns $matched directly
    # rather than via a switch expression — a plain @(...) assignment inside an
    # if/elseif branch is the form that survives a 0-match result as an empty
    # array rather than collapsing it to $null.
    if     ($PSCmdlet.ParameterSetName -eq 'ById')   { $matched = @($groups | Where-Object { $_.GroupId -eq $GroupId }) }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByName') { $matched = @($groups | Where-Object { $_.Name -like $Name }) }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByType') { $matched = @($groups | Where-Object { $_.Type -eq $Type }) }
    else                                              { $matched = @($groups) }

    if ($matched.Count -eq 0) { return ,@() }
    return $matched
}

function Remove-HvDRSGroup {
    <#
    .SYNOPSIS
        Removes an HVDRS group by ID or name.

    .DESCRIPTION
        Does not check whether any affinity rule references this group — removing
        a referenced group simply means that rule stops picking up its members on
        the next load (the rule's own literal VMs/Hosts/CSVs, if any, are
        unaffected).
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById',   Mandatory)] [string] $GroupId,
        [Parameter(ParameterSetName = 'ByName', Mandatory)] [string] $Name,
        [string] $ClusterName = '',
        [string] $GroupsPath  = $script:HvDRSDefaultGroupsPath
    )

    $groups = [System.Collections.Generic.List[PSCustomObject]](Get-HvDRSGroupSet -Path $GroupsPath)

    $target = if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $groups | Where-Object { $_.GroupId -eq $GroupId }
    } else {
        $groups | Where-Object {
            $_.Name -eq $Name -and (-not $ClusterName -or $_.ClusterName -eq $ClusterName)
        }
    }

    if (-not $target) {
        Write-Warning "No group found matching the specified criteria."
        return
    }
    if (@($target).Count -gt 1) {
        Write-Warning "Multiple groups match name '$Name'. Use -GroupId to remove a specific group."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove HvDRS group')) { return }

    [void]$groups.Remove($target)
    Save-HvDRSGroupSet -Groups $groups.ToArray() -Path $GroupsPath
    Write-Host "Group '$($target.Name)' removed."
}

function Set-HvDRSGroup {
    <#
    .SYNOPSIS
        Updates the members or description of an existing HVDRS group.

    .PARAMETER GroupId
        ID of the group to update (use Get-HvDRSGroup to find it).

    .PARAMETER NewName
        Rename the group.

    .PARAMETER AddMembers
        Add member names to the group.

    .PARAMETER RemoveMembers
        Remove member names from the group.

    .PARAMETER Description
        Replace the group's description text.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]   $GroupId,
        [string]   $NewName,
        [string[]] $AddMembers    = @(),
        [string[]] $RemoveMembers = @(),
        [string]   $Description,
        [string]   $GroupsPath    = $script:HvDRSDefaultGroupsPath
    )

    $groups = [System.Collections.Generic.List[PSCustomObject]](Get-HvDRSGroupSet -Path $GroupsPath)
    $group  = $groups | Where-Object { $_.GroupId -eq $GroupId }

    if (-not $group) {
        Write-Warning "No group found with ID '$GroupId'."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($group.Name, 'Update HvDRS group')) { return }

    if ($PSBoundParameters.ContainsKey('NewName'))     { $group.Name        = $NewName }
    if ($PSBoundParameters.ContainsKey('Description')) { $group.Description = $Description }

    if ($AddMembers.Count -gt 0) {
        $group.Members = @(@($group.Members) + $AddMembers | Select-Object -Unique)
    }
    if ($RemoveMembers.Count -gt 0) {
        $group.Members = @(@($group.Members) | Where-Object { $RemoveMembers -notcontains $_ })
    }

    Save-HvDRSGroupSet -Groups $groups.ToArray() -Path $GroupsPath
    Write-Host "Group '$($group.Name)' updated."
    return $group
}
