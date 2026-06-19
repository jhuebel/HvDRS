$script:HvDRSValidRuleTypes  = @('VmVmAffinity', 'VmVmAntiAffinity', 'VmHostAffinity', 'VmHostAntiAffinity')
$script:HvDRSDefaultRulesPath = Join-Path $env:ProgramData 'HvDRS\rules.json'

function Add-HvDRSAffinityRule {
    <#
    .SYNOPSIS
        Defines a new affinity or anti-affinity rule for HvDRS to enforce during migration planning.

    .PARAMETER ClusterName
        Name of the Failover Cluster this rule applies to. Rules are stored in a shared
        JSON file and filtered by cluster at load time, so the same file can hold rules
        for multiple clusters without interference.
        Defaults to the local cluster if omitted.

    .PARAMETER Name
        Human-readable name for the rule. Must be unique within a cluster (the same
        name may be reused across different clusters).

    .PARAMETER Type
        VmVmAffinity        — Keep the listed VMs on the same host.
        VmVmAntiAffinity    — Keep the listed VMs on different hosts.
        VmHostAffinity      — Run the listed VMs only on the specified hosts.
        VmHostAntiAffinity  — Never run the listed VMs on the specified hosts.

    .PARAMETER VMs
        VM names covered by this rule.
        VmVmAffinity / VmVmAntiAffinity require at least two VM names.
        VmHostAffinity / VmHostAntiAffinity require at least one VM name.

    .PARAMETER Hosts
        Required for VmHostAffinity and VmHostAntiAffinity.
        Node names of the hosts involved in the rule.

    .PARAMETER Enforced
        Hard rule: HvDRS will never execute a migration that would break this rule, and will
        proactively schedule compliance migrations to fix existing violations.
        Without this switch the rule is soft: violations are penalised in the happiness score
        but not blocked.

    .PARAMETER Description
        Optional free-text description stored with the rule.

    .PARAMETER RulesPath
        Path to the JSON rule store. Defaults to $env:ProgramData\HvDRS\rules.json.

    .EXAMPLE
        Add-HvDRSAffinityRule -ClusterName 'PROD-CLUSTER' -Name 'DC Anti-Affinity' `
                              -Type VmVmAntiAffinity -VMs 'DC-01','DC-02' -Enforced

    .EXAMPLE
        Add-HvDRSAffinityRule -ClusterName 'PROD-CLUSTER' -Name 'SQL Licensing' `
                              -Type VmHostAffinity -VMs 'SQL-PROD-01' `
                              -Hosts 'HV-NODE1','HV-NODE2' -Enforced
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]   $ClusterName = '',
        [Parameter(Mandatory)] [string]   $Name,
        [Parameter(Mandatory)]
        [ValidateSet('VmVmAffinity','VmVmAntiAffinity','VmHostAffinity','VmHostAntiAffinity')]
        [string]   $Type,
        [Parameter(Mandatory)] [string[]] $VMs,
        [string[]] $Hosts       = @(),
        [switch]   $Enforced,
        [string]   $Description = '',
        [string]   $RulesPath   = $script:HvDRSDefaultRulesPath
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    # Validate minimum membership
    if ($Type -in @('VmVmAffinity','VmVmAntiAffinity') -and $VMs.Count -lt 2) {
        throw "$Type rules require at least two VM names."
    }
    if ($Type -in @('VmHostAffinity','VmHostAntiAffinity') -and $Hosts.Count -eq 0) {
        throw "$Type rules require at least one host name via -Hosts."
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Add HvDRS $Type rule for cluster '$ClusterName'")) { return }

    # Load ALL rules (unfiltered) so we can save the full set back
    $rules = [System.Collections.Generic.List[PSCustomObject]](Get-AffinityRuleSet -Path $RulesPath)

    # Duplicate check is scoped to the same cluster
    if ($rules | Where-Object { $_.ClusterName -eq $ClusterName -and $_.Name -eq $Name }) {
        Write-Warning "A rule named '$Name' already exists for cluster '$ClusterName'. Use Set-HvDRSAffinityRule to modify it."
        return
    }

    $rule = [PSCustomObject]@{
        RuleId      = [System.Guid]::NewGuid().ToString()
        Name        = $Name
        ClusterName = $ClusterName
        Type        = $Type
        Enforced    = [bool]$Enforced
        VMs         = @($VMs)
        Hosts       = @($Hosts)
        Description = $Description
        CreatedAt   = (Get-Date -Format 'o')
    }

    $rules.Add($rule)
    Save-AffinityRuleSet -Rules $rules.ToArray() -Path $RulesPath

    Write-Host "Rule '$Name' added for cluster '$ClusterName' (ID: $($rule.RuleId))."
    return $rule
}

function Get-HvDRSAffinityRule {
    <#
    .SYNOPSIS
        Lists HvDRS affinity and anti-affinity rules, with optional filtering.

    .PARAMETER ClusterName
        When specified, returns only rules belonging to this cluster.
        Omit to return rules for all clusters (useful for auditing the shared file).

    .PARAMETER RuleId
        Return the rule with this specific ID.

    .PARAMETER Name
        Filter by name. Supports wildcards (e.g. 'DC*').

    .PARAMETER Type
        Filter by rule type.

    .PARAMETER VmName
        Return only rules that reference this VM name.

    .PARAMETER RulesPath
        Path to the JSON rule store.
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    param(
        [string] $ClusterName = '',
        [Parameter(ParameterSetName = 'ById',   Mandatory)] [string] $RuleId,
        [Parameter(ParameterSetName = 'ByName')]             [string] $Name,
        [Parameter(ParameterSetName = 'ByType')]
        [ValidateSet('VmVmAffinity','VmVmAntiAffinity','VmHostAffinity','VmHostAntiAffinity')]
        [string] $Type,
        [Parameter(ParameterSetName = 'ByVm')]  [string] $VmName,
        [string] $RulesPath = $script:HvDRSDefaultRulesPath
    )

    $rules = Get-AffinityRuleSet -Path $RulesPath -ClusterName $ClusterName

    switch ($PSCmdlet.ParameterSetName) {
        'ById'   { return @($rules | Where-Object { $_.RuleId -eq $RuleId }) }
        'ByName' { return @($rules | Where-Object { $_.Name -like $Name }) }
        'ByType' { return @($rules | Where-Object { $_.Type -eq $Type }) }
        'ByVm'   { return @($rules | Where-Object { $_.VMs -contains $VmName }) }
        default  { return @($rules) }
    }
}

function Remove-HvDRSAffinityRule {
    <#
    .SYNOPSIS
        Removes an HvDRS affinity rule by ID or name.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById',   Mandatory)] [string] $RuleId,
        [Parameter(ParameterSetName = 'ByName', Mandatory)] [string] $Name,
        [string] $ClusterName = '',
        [string] $RulesPath   = $script:HvDRSDefaultRulesPath
    )

    # Load ALL rules unfiltered — we need the full set to save back correctly
    $rules = [System.Collections.Generic.List[PSCustomObject]](Get-AffinityRuleSet -Path $RulesPath)

    $target = if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $rules | Where-Object { $_.RuleId -eq $RuleId }
    } else {
        # Scope name lookup to the cluster when provided; avoids cross-cluster collisions
        $rules | Where-Object {
            $_.Name -eq $Name -and (-not $ClusterName -or $_.ClusterName -eq $ClusterName)
        }
    }

    if (-not $target) {
        Write-Warning "No rule found matching the specified criteria."
        return
    }
    if (@($target).Count -gt 1) {
        Write-Warning "Multiple rules match name '$Name'. Use -RuleId to remove a specific rule."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove HvDRS affinity rule')) { return }

    [void]$rules.Remove($target)
    Save-AffinityRuleSet -Rules $rules.ToArray() -Path $RulesPath
    Write-Host "Rule '$($target.Name)' removed."
}

function Set-HvDRSAffinityRule {
    <#
    .SYNOPSIS
        Updates properties of an existing HvDRS affinity rule.

    .PARAMETER RuleId
        ID of the rule to update (use Get-HvDRSAffinityRule to find it).

    .PARAMETER NewName
        Rename the rule.

    .PARAMETER Enforced
        Change the enforcement mode. Use -Enforced:$false to make the rule soft.

    .PARAMETER AddVMs
        Add VM names to the rule's VM list.

    .PARAMETER RemoveVMs
        Remove VM names from the rule's VM list.

    .PARAMETER AddHosts
        Add host names to the rule's host list (VmHostAffinity / VmHostAntiAffinity only).

    .PARAMETER RemoveHosts
        Remove host names from the rule's host list.

    .PARAMETER Description
        Replace the rule's description text.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]   $RuleId,
        [string]   $NewName,
        [nullable[bool]] $Enforced,
        [string[]] $AddVMs      = @(),
        [string[]] $RemoveVMs   = @(),
        [string[]] $AddHosts    = @(),
        [string[]] $RemoveHosts = @(),
        [string]   $Description,
        [string]   $RulesPath   = $script:HvDRSDefaultRulesPath
    )

    $rules = [System.Collections.Generic.List[PSCustomObject]](Get-AffinityRuleSet -Path $RulesPath)
    $rule  = $rules | Where-Object { $_.RuleId -eq $RuleId }

    if (-not $rule) {
        Write-Warning "No rule found with ID '$RuleId'."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($rule.Name, 'Update HvDRS affinity rule')) { return }

    if ($PSBoundParameters.ContainsKey('NewName'))     { $rule.Name        = $NewName }
    if ($PSBoundParameters.ContainsKey('Enforced'))    { $rule.Enforced    = [bool]$Enforced }
    if ($PSBoundParameters.ContainsKey('Description')) { $rule.Description = $Description }

    if ($AddVMs.Count -gt 0) {
        $rule.VMs = @($rule.VMs + $AddVMs | Select-Object -Unique)
    }
    if ($RemoveVMs.Count -gt 0) {
        $rule.VMs = @($rule.VMs | Where-Object { $RemoveVMs -notcontains $_ })
    }
    if ($AddHosts.Count -gt 0) {
        $rule.Hosts = @($rule.Hosts + $AddHosts | Select-Object -Unique)
    }
    if ($RemoveHosts.Count -gt 0) {
        $rule.Hosts = @($rule.Hosts | Where-Object { $RemoveHosts -notcontains $_ })
    }

    # Re-validate minimum membership after edits
    if ($rule.Type -in @('VmVmAffinity','VmVmAntiAffinity') -and $rule.VMs.Count -lt 2) {
        throw "Rule '$($rule.Name)' would have fewer than 2 VMs — $($rule.Type) requires at least 2."
    }

    Save-AffinityRuleSet -Rules $rules.ToArray() -Path $RulesPath
    Write-Host "Rule '$($rule.Name)' updated."
    return $rule
}

function Test-HvDRSAffinityCompliance {
    <#
    .SYNOPSIS
        Collects a live cluster snapshot and checks it against all configured rules,
        reporting any current violations.

    .PARAMETER ClusterName
        Target Failover Cluster. Defaults to the local cluster.

    .PARAMETER RulesPath
        Path to the JSON rule store.

    .EXAMPLE
        Test-HvDRSAffinityCompliance -ClusterName 'PROD-CLUSTER'
    #>
    [CmdletBinding()]
    param(
        [string] $ClusterName,
        [string] $RulesPath = $script:HvDRSDefaultRulesPath
    )

    if (-not $ClusterName) {
        try { $ClusterName = (Get-Cluster -ErrorAction Stop).Name }
        catch { throw "No -ClusterName specified and no local cluster detected. $_" }
    }

    $ruleSet = Get-AffinityRuleSet -Path $RulesPath -ClusterName $ClusterName
    if (-not $ruleSet -or $ruleSet.Count -eq 0) {
        Write-Host "No affinity rules are defined for cluster '$ClusterName'. Add rules with Add-HvDRSAffinityRule -ClusterName '$ClusterName'."
        return @()
    }

    Write-Host "Collecting cluster placement snapshot..."
    $snapshot = Get-ClusterSnapshot -ClusterName $ClusterName -SampleCount 1 -SampleIntervalSeconds 1

    $violations = Test-AffinityCompliance -Snapshot $snapshot -RuleSet $ruleSet

    if (-not $violations -or $violations.Count -eq 0) {
        Write-Host "All $($ruleSet.Count) affinity rule(s) for cluster '$ClusterName' are satisfied."
        return @()
    }

    $hardCount = @($violations | Where-Object { $_.Enforced }).Count
    $softCount = $violations.Count - $hardCount

    Write-Host ''
    Write-Host ("── {0} Rule Violation(s) — {1} hard, {2} soft ─────────────────────────────────────" -f
        $violations.Count, $hardCount, $softCount)

    $violations | Format-Table -AutoSize -Wrap -Property `
        @{ N='Rule';     E={ $_.RuleName } },
        @{ N='Type';     E={ $_.Type } },
        @{ N='Enforced'; E={ $_.Enforced } },
        @{ N='VMs';      E={ $_.VMs -join ', ' } },
        @{ N='Detail';   E={ $_.Description } }

    return $violations
}
