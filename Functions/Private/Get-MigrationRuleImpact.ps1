function Get-MigrationRuleImpact {
    <#
    .SYNOPSIS
        Evaluates whether a proposed live migration would break, fix, or be neutral
        with respect to the configured affinity and anti-affinity rules.

    .DESCRIPTION
        For each rule that references the VM being migrated, the function simulates
        the post-migration placement and compares it to the current placement:

          Break (currently satisfied → will be violated):
            Hard rule → HasHardViolation = $true  (caller should exclude this destination)
            Soft rule → HasSoftViolation = $true  (caller should apply a score penalty)

          Fix (currently violated → will be satisfied):
            → FixesViolation = $true  (caller should apply a score bonus)

          Neutral (no change in satisfaction status) → no flags set.

    .OUTPUTS
        PSCustomObject: HasHardViolation, HasSoftViolation, FixesViolation,
                        HardReasons[], SoftReasons[], FixReasons[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]          $VMName,
        [Parameter(Mandatory)] [string]          $DestinationNode,
        [Parameter(Mandatory)] [PSCustomObject]  $Snapshot,
        [PSCustomObject[]]                        $RuleSet
    )

    $empty = [PSCustomObject]@{
        HasHardViolation = $false
        HasSoftViolation = $false
        FixesViolation   = $false
        HardReasons      = @()
        SoftReasons      = @()
        FixReasons       = @()
    }

    if (-not $RuleSet -or $RuleSet.Count -eq 0) { return $empty }

    # Current placement: VMName → HostNode
    $vmHost = @{}
    foreach ($vm in $Snapshot.VMs) { $vmHost[$vm.VMName] = $vm.HostNode }

    $hardReasons = [System.Collections.Generic.List[string]]::new()
    $softReasons = [System.Collections.Generic.List[string]]::new()
    $fixReasons  = [System.Collections.Generic.List[string]]::new()

    foreach ($rule in $RuleSet) {
        if ($rule.VMs -notcontains $VMName) { continue }

        $activeVMs = @($rule.VMs | Where-Object { $vmHost.ContainsKey($_) })
        if ($activeVMs.Count -eq 0) { continue }

        $severity = if ($rule.Enforced) { 'enforced' } else { 'soft' }

        switch ($rule.Type) {

            'VmVmAffinity' {
                # All members must share one host.
                $currentHosts = @($activeVMs | ForEach-Object { $vmHost[$_] } | Select-Object -Unique)
                $simHosts     = @($activeVMs | ForEach-Object {
                    if ($_ -eq $VMName) { $DestinationNode } else { $vmHost[$_] }
                } | Select-Object -Unique)

                $wasSatisfied  = $currentHosts.Count -le 1
                $willSatisfied = $simHosts.Count     -le 1

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity affinity rule '$($rule.Name)' — members would span: $($simHosts -join ', ')"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies affinity rule '$($rule.Name)' — all members consolidated on '$DestinationNode'")
                }
            }

            'VmVmAntiAffinity' {
                # No two members may share a host.
                $currentConflicts = @($activeVMs | Group-Object { $vmHost[$_]  } | Where-Object { $_.Count -gt 1 })
                $simConflicts     = @($activeVMs | Group-Object {
                    if ($_ -eq $VMName) { $DestinationNode } else { $vmHost[$_] }
                } | Where-Object { $_.Count -gt 1 })

                $wasSatisfied  = $currentConflicts.Count -eq 0
                $willSatisfied = $simConflicts.Count     -eq 0

                if ($wasSatisfied -and -not $willSatisfied) {
                    $peer = ($simConflicts[0].Group | Where-Object { $_ -ne $VMName })[0]
                    $msg  = "Breaks $severity anti-affinity rule '$($rule.Name)' — '$VMName' would share '$DestinationNode' with '$peer'"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies anti-affinity rule '$($rule.Name)' — '$VMName' separated from all group members")
                }
            }

            'VmHostAffinity' {
                # VM must reside on one of the listed hosts.
                $wasSatisfied  = $rule.Hosts -contains $vmHost[$VMName]
                $willSatisfied = $rule.Hosts -contains $DestinationNode

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity host-affinity rule '$($rule.Name)' — '$DestinationNode' is not in [$(($rule.Hosts) -join ', ')]"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies host-affinity rule '$($rule.Name)' — '$VMName' moves onto allowed host '$DestinationNode'")
                }
            }

            'VmHostAntiAffinity' {
                # VM must NOT reside on any of the listed hosts.
                $wasSatisfied  = $rule.Hosts -notcontains $vmHost[$VMName]
                $willSatisfied = $rule.Hosts -notcontains $DestinationNode

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity host-anti-affinity rule '$($rule.Name)' — '$DestinationNode' is an excluded host"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies host-anti-affinity rule '$($rule.Name)' — '$VMName' moves off excluded host")
                }
            }
        }
    }

    [PSCustomObject]@{
        HasHardViolation = $hardReasons.Count -gt 0
        HasSoftViolation = $softReasons.Count -gt 0
        FixesViolation   = $fixReasons.Count  -gt 0
        HardReasons      = $hardReasons.ToArray()
        SoftReasons      = $softReasons.ToArray()
        FixReasons       = $fixReasons.ToArray()
    }
}
