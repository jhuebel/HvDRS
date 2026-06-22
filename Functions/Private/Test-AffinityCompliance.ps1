function Test-AffinityCompliance {
    <#
    .SYNOPSIS
        Checks the current cluster placement against all configured affinity rules
        and returns a list of violations.

    .OUTPUTS
        Array of PSCustomObjects: RuleId, RuleName, Type, Enforced, VMs, Description.
        VMs contains the names of the VMs directly involved in this specific violation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]  $Snapshot,
        [PSCustomObject[]]                        $RuleSet
    )

    if (-not $RuleSet -or $RuleSet.Count -eq 0) { return ,@() }

    $vmHost = @{}
    foreach ($vm in $Snapshot.VMs) { $vmHost[$vm.VMName] = $vm.HostNode }

    $violations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($rule in $RuleSet) {
        $activeVMs = @($rule.VMs | Where-Object { $vmHost.ContainsKey($_) })
        if ($activeVMs.Count -eq 0) { continue }

        switch ($rule.Type) {

            'VmVmAffinity' {
                $hostGroups = @($activeVMs | Group-Object { $vmHost[$_] })
                if ($hostGroups.Count -gt 1) {
                    $hostList = $hostGroups | Select-Object -ExpandProperty Name
                    $violations.Add([PSCustomObject]@{
                        RuleId      = $rule.RuleId
                        RuleName    = $rule.Name
                        Type        = $rule.Type
                        Enforced    = $rule.Enforced
                        VMs         = $activeVMs
                        Description = "Affinity group '$($rule.Name)' is spread across $($hostGroups.Count) host(s): $($hostList -join ', ')"
                    })
                }
            }

            'VmVmAntiAffinity' {
                $conflicts = @($activeVMs | Group-Object { $vmHost[$_] } | Where-Object { $_.Count -gt 1 })
                foreach ($conflict in $conflicts) {
                    $violations.Add([PSCustomObject]@{
                        RuleId      = $rule.RuleId
                        RuleName    = $rule.Name
                        Type        = $rule.Type
                        Enforced    = $rule.Enforced
                        VMs         = @($conflict.Group)
                        Description = "Anti-affinity rule '$($rule.Name)': '$($conflict.Group -join "', '")' co-located on '$($conflict.Name)'"
                    })
                }
            }

            'VmHostAffinity' {
                foreach ($vm in $activeVMs) {
                    if ($rule.Hosts -notcontains $vmHost[$vm]) {
                        $violations.Add([PSCustomObject]@{
                            RuleId      = $rule.RuleId
                            RuleName    = $rule.Name
                            Type        = $rule.Type
                            Enforced    = $rule.Enforced
                            VMs         = @($vm)
                            Description = "Host-affinity rule '$($rule.Name)': '$vm' is on '$($vmHost[$vm])' — allowed: [$($rule.Hosts -join ', ')]"
                        })
                    }
                }
            }

            'VmHostAntiAffinity' {
                foreach ($vm in $activeVMs) {
                    if ($rule.Hosts -contains $vmHost[$vm]) {
                        $violations.Add([PSCustomObject]@{
                            RuleId      = $rule.RuleId
                            RuleName    = $rule.Name
                            Type        = $rule.Type
                            Enforced    = $rule.Enforced
                            VMs         = @($vm)
                            Description = "Host-anti-affinity rule '$($rule.Name)': '$vm' is on excluded host '$($vmHost[$vm])'"
                        })
                    }
                }
            }
        }
    }

    return $violations.ToArray()
}
