function Test-StorageAffinityCompliance {
    <#
    .SYNOPSIS
        Checks the current VM-to-CSV storage placement against all configured storage
        affinity rules and returns a list of violations.

    .DESCRIPTION
        Storage analogue of Test-AffinityCompliance. Operates on a storage snapshot
        (Get-StorageSnapshot) instead of a compute snapshot, and only evaluates the
        four storage rule types:
          VmVmCsvAffinity     — listed VMs' storage must share one CSV.
          VmVmCsvAntiAffinity — no two listed VMs may share a CSV.
          VmCsvAffinity       — listed VMs' storage must be on one of the named CSVs.
          VmCsvAntiAffinity   — listed VMs' storage must never be on the named CSVs.

    .OUTPUTS
        Array of PSCustomObjects: RuleId, RuleName, Type, Enforced, VMs, Description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]  $Snapshot,
        [PSCustomObject[]]                        $RuleSet
    )

    if (-not $RuleSet -or $RuleSet.Count -eq 0) { return ,@() }

    $pathToName = @{}
    foreach ($csv in $Snapshot.CSVs) { $pathToName[$csv.Path] = $csv.Name }

    $vmCsv = @{}
    foreach ($vm in $Snapshot.VMs) {
        $vmCsv[$vm.VMName] = if ($pathToName.ContainsKey($vm.PrimaryCSV)) { $pathToName[$vm.PrimaryCSV] } else { $vm.PrimaryCSV }
    }

    $violations = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($rule in $RuleSet) {
        $activeVMs = @($rule.VMs | Where-Object { $vmCsv.ContainsKey($_) })
        if ($activeVMs.Count -eq 0) { continue }

        switch ($rule.Type) {

            'VmVmCsvAffinity' {
                $csvGroups = @($activeVMs | Group-Object { $vmCsv[$_] })
                if ($csvGroups.Count -gt 1) {
                    $csvList = $csvGroups | Select-Object -ExpandProperty Name
                    $violations.Add([PSCustomObject]@{
                        RuleId      = $rule.RuleId
                        RuleName    = $rule.Name
                        Type        = $rule.Type
                        Enforced    = $rule.Enforced
                        VMs         = $activeVMs
                        Description = "Storage affinity group '$($rule.Name)' is spread across $($csvGroups.Count) CSV(s): $($csvList -join ', ')"
                    })
                }
            }

            'VmVmCsvAntiAffinity' {
                $conflicts = @($activeVMs | Group-Object { $vmCsv[$_] } | Where-Object { $_.Count -gt 1 })
                foreach ($conflict in $conflicts) {
                    $violations.Add([PSCustomObject]@{
                        RuleId      = $rule.RuleId
                        RuleName    = $rule.Name
                        Type        = $rule.Type
                        Enforced    = $rule.Enforced
                        VMs         = @($conflict.Group)
                        Description = "Storage anti-affinity rule '$($rule.Name)': '$($conflict.Group -join "', '")' co-located on CSV '$($conflict.Name)'"
                    })
                }
            }

            'VmCsvAffinity' {
                foreach ($vm in $activeVMs) {
                    if ($rule.CSVs -notcontains $vmCsv[$vm]) {
                        $violations.Add([PSCustomObject]@{
                            RuleId      = $rule.RuleId
                            RuleName    = $rule.Name
                            Type        = $rule.Type
                            Enforced    = $rule.Enforced
                            VMs         = @($vm)
                            Description = "CSV-affinity rule '$($rule.Name)': '$vm' storage is on '$($vmCsv[$vm])' — allowed: [$($rule.CSVs -join ', ')]"
                        })
                    }
                }
            }

            'VmCsvAntiAffinity' {
                foreach ($vm in $activeVMs) {
                    if ($rule.CSVs -contains $vmCsv[$vm]) {
                        $violations.Add([PSCustomObject]@{
                            RuleId      = $rule.RuleId
                            RuleName    = $rule.Name
                            Type        = $rule.Type
                            Enforced    = $rule.Enforced
                            VMs         = @($vm)
                            Description = "CSV-anti-affinity rule '$($rule.Name)': '$vm' storage is on excluded CSV '$($vmCsv[$vm])'"
                        })
                    }
                }
            }
        }
    }

    return $violations.ToArray()
}
