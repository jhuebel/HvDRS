function Get-AffinityRuleSet {
    <#
    .SYNOPSIS
        Loads affinity/anti-affinity rules from the JSON rule store, expanding any
        -VMGroups/-HostGroups/-CSVGroups references into the rule's VMs/Hosts/CSVs
        arrays before returning.

    .DESCRIPTION
        Group expansion happens here, at read time, rather than being denormalized
        into the rule at write time — every downstream consumer (Test-AffinityCompliance,
        Get-MigrationRuleImpact, Find-MigrationCandidates, and the storage
        equivalents) only ever reads $rule.VMs/.Hosts/.CSVs and needs no changes.
        Editing a group's membership with Set-HvDRSGroup therefore takes effect on
        the very next read of any rule that references it, with no rule re-save
        required. A missing groups.json degrades gracefully to "no groups defined" —
        rules behave exactly as if only their literal VMs/Hosts/CSVs were set.

        -SkipGroupExpansion returns rules exactly as stored, with no group
        expansion. Add/Remove/Set-HvDRSAffinityRule use this when they load the
        full rule set only to modify one rule and resave the whole file — without
        it, the expanded (VMs+group-members) arrays would get baked into the JSON
        on every resave, defeating dynamic group resolution and growing the file
        a little more with each edit.
    #>
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$Path        = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json'),
        [string]$GroupsPath  = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\groups.json'),
        [switch]$SkipGroupExpansion
    )

    # PowerShell collapses a 0-element array to $null when it crosses the function
    # output boundary. The leading comma forces an empty array to survive so direct
    # casts/captures (e.g. [List[T]](Get-AffinityRuleSet ...)) get a real empty
    # collection instead of $null. It is intentionally NOT applied when the array
    # is non-empty — comma-protecting a populated array would make it cross the
    # boundary as a single pipeline object, breaking `Get-AffinityRuleSet | Where-Object`
    # style consumption elsewhere in this module.
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    try {
        $data  = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $rules = @($data.Rules)
        if ($ClusterName) {
            $rules = @($rules | Where-Object { $_.ClusterName -eq $ClusterName })
        }
        if ($rules.Count -eq 0) { return ,@() }
        if ($SkipGroupExpansion) { return $rules }

        $groups = Get-HvDRSGroupSet -Path $GroupsPath -ClusterName $ClusterName
        if ($groups.Count -gt 0) {
            foreach ($rule in $rules) {
                # Rules persisted before groups existed (or hand-edited JSON) won't
                # have these properties at all — PSObject.Properties[$name] is a
                # safe existence check that doesn't throw under Set-StrictMode,
                # unlike dot-accessing a genuinely missing property would.
                #
                # The whole if-expression is wrapped in the OUTER @(...) rather than
                # wrapping @() only around the true-branch's value: assigning the
                # result of an if/else used as an expression re-applies PowerShell's
                # "a single emitted object doesn't get re-collected into an array"
                # rule to the if-statement's own output, regardless of whether the
                # branch's value was itself already an array — e.g. a rule with
                # exactly one -VMGroups entry would otherwise collapse to a bare
                # string here, which has no .Count under Set-StrictMode (unlike
                # PSCustomObject, which gets a synthetic one).
                $vmGroups   = @( if ($rule.PSObject.Properties['VMGroups'])   { $rule.VMGroups } )
                $hostGroups = @( if ($rule.PSObject.Properties['HostGroups']) { $rule.HostGroups } )
                $csvGroups  = @( if ($rule.PSObject.Properties['CSVGroups'])  { $rule.CSVGroups } )

                if ($vmGroups.Count -gt 0) {
                    $vmGroupMembers = @($groups | Where-Object { $_.Type -eq 'Vm' -and $vmGroups -contains $_.Name } |
                                        ForEach-Object { $_.Members })
                    $rule.VMs = @(@($rule.VMs) + $vmGroupMembers | Select-Object -Unique)
                }
                if ($hostGroups.Count -gt 0) {
                    $hostGroupMembers = @($groups | Where-Object { $_.Type -eq 'Host' -and $hostGroups -contains $_.Name } |
                                          ForEach-Object { $_.Members })
                    $rule.Hosts = @(@($rule.Hosts) + $hostGroupMembers | Select-Object -Unique)
                }
                if ($csvGroups.Count -gt 0) {
                    $csvGroupMembers = @($groups | Where-Object { $_.Type -eq 'Csv' -and $csvGroups -contains $_.Name } |
                                         ForEach-Object { $_.Members })
                    $rule.CSVs = @(@($rule.CSVs) + $csvGroupMembers | Select-Object -Unique)
                }
            }
        }

        return $rules
    } catch {
        Write-Warning "Could not load affinity rules from '$Path': $_"
        return ,@()
    }
}

function Save-AffinityRuleSet {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Rules,
        [string]$Path = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json')
    )

    $dir = Split-Path -LiteralPath $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject]@{
        Version     = '1.0'
        LastUpdated = (Get-Date -Format 'o')
        Rules       = if ($Rules) { $Rules } else { @() }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}
