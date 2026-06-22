function Get-StorageMigrationRuleImpact {
    <#
    .SYNOPSIS
        Evaluates whether a proposed storage migration (moving a VM's VHDs to a
        different CSV) would break, fix, or be neutral with respect to the configured
        storage affinity / anti-affinity rules.

    .DESCRIPTION
        Storage analogue of Get-MigrationRuleImpact. For each storage rule that
        references the VM being migrated, simulates the post-migration CSV placement
        and compares it to the current placement:

          Break (currently satisfied → will be violated):
            Hard rule → HasHardViolation = $true  (caller should exclude this destination)
            Soft rule → HasSoftViolation = $true  (caller should apply a score penalty)

          Fix (currently violated → will be satisfied):
            → FixesViolation = $true  (caller should apply a score bonus)

    .OUTPUTS
        PSCustomObject: HasHardViolation, HasSoftViolation, FixesViolation,
                        HardReasons[], SoftReasons[], FixReasons[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]          $VMName,
        [Parameter(Mandatory)] [string]          $DestinationCsvName,
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

    $pathToName = @{}
    foreach ($csv in $Snapshot.CSVs) { $pathToName[$csv.Path] = $csv.Name }

    $vmCsv = @{}
    foreach ($vm in $Snapshot.VMs) {
        $vmCsv[$vm.VMName] = if ($pathToName.ContainsKey($vm.PrimaryCSV)) { $pathToName[$vm.PrimaryCSV] } else { $vm.PrimaryCSV }
    }

    $hardReasons = [System.Collections.Generic.List[string]]::new()
    $softReasons = [System.Collections.Generic.List[string]]::new()
    $fixReasons  = [System.Collections.Generic.List[string]]::new()

    foreach ($rule in $RuleSet) {
        if ($rule.VMs -notcontains $VMName) { continue }

        $activeVMs = @($rule.VMs | Where-Object { $vmCsv.ContainsKey($_) })
        if ($activeVMs.Count -eq 0) { continue }

        $severity = if ($rule.Enforced) { 'enforced' } else { 'soft' }

        switch ($rule.Type) {

            'VmVmCsvAffinity' {
                # All members must share one CSV.
                $currentCsvs = @($activeVMs | ForEach-Object { $vmCsv[$_] } | Select-Object -Unique)
                $simCsvs     = @($activeVMs | ForEach-Object {
                    if ($_ -eq $VMName) { $DestinationCsvName } else { $vmCsv[$_] }
                } | Select-Object -Unique)

                $wasSatisfied  = $currentCsvs.Count -le 1
                $willSatisfied = $simCsvs.Count     -le 1

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity storage affinity rule '$($rule.Name)' — members would span CSVs: $($simCsvs -join ', ')"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies storage affinity rule '$($rule.Name)' — all members consolidated on CSV '$DestinationCsvName'")
                }
            }

            'VmVmCsvAntiAffinity' {
                # No two members may share a CSV.
                $currentConflicts = @($activeVMs | Group-Object { $vmCsv[$_] } | Where-Object { $_.Count -gt 1 })
                $simConflicts     = @($activeVMs | Group-Object {
                    if ($_ -eq $VMName) { $DestinationCsvName } else { $vmCsv[$_] }
                } | Where-Object { $_.Count -gt 1 })

                $wasSatisfied  = $currentConflicts.Count -eq 0
                $willSatisfied = $simConflicts.Count     -eq 0

                if ($wasSatisfied -and -not $willSatisfied) {
                    $peer = ($simConflicts[0].Group | Where-Object { $_ -ne $VMName })[0]
                    $msg  = "Breaks $severity storage anti-affinity rule '$($rule.Name)' — '$VMName' would share CSV '$DestinationCsvName' with '$peer'"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies storage anti-affinity rule '$($rule.Name)' — '$VMName' separated from all group members")
                }
            }

            'VmCsvAffinity' {
                # VM's storage must reside on one of the listed CSVs.
                $wasSatisfied  = $rule.CSVs -contains $vmCsv[$VMName]
                $willSatisfied = $rule.CSVs -contains $DestinationCsvName

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity CSV-affinity rule '$($rule.Name)' — '$DestinationCsvName' is not in [$(($rule.CSVs) -join ', ')]"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies CSV-affinity rule '$($rule.Name)' — '$VMName' moves onto allowed CSV '$DestinationCsvName'")
                }
            }

            'VmCsvAntiAffinity' {
                # VM's storage must NOT reside on any of the listed CSVs.
                $wasSatisfied  = $rule.CSVs -notcontains $vmCsv[$VMName]
                $willSatisfied = $rule.CSVs -notcontains $DestinationCsvName

                if ($wasSatisfied -and -not $willSatisfied) {
                    $msg = "Breaks $severity CSV-anti-affinity rule '$($rule.Name)' — '$DestinationCsvName' is an excluded CSV"
                    if ($rule.Enforced) { $hardReasons.Add($msg) } else { $softReasons.Add($msg) }
                } elseif (-not $wasSatisfied -and $willSatisfied) {
                    $fixReasons.Add("Satisfies CSV-anti-affinity rule '$($rule.Name)' — '$VMName' moves off excluded CSV")
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
