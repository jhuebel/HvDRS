#Requires -Module Pester
<#
    Unit tests for the public affinity-rule CRUD functions:
        Add-HvDRSAffinityRule
        Get-HvDRSAffinityRule
        Remove-HvDRSAffinityRule
        Set-HvDRSAffinityRule

    All tests use a per-test temporary file so they never touch the real rule store
    at $env:ProgramData\HvDRS\rules.json.
    No FailoverClusters or Hyper-V modules are required.
#>

# Pester 5 does not allow BeforeEach/AfterEach directly at the root of a block
# container, so the whole file lives inside one outer Describe.
Describe 'AffinityRules' {

BeforeAll {
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSDataRoot.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSGroupSet.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-AffinityRuleSet.ps1"
    . "$PSScriptRoot/../Functions/Public/AffinityRules.ps1"
    . "$PSScriptRoot/../Functions/Public/Groups.ps1"
}

# Each test gets its own temp file path via BeforeEach / AfterEach
BeforeEach {
    $testRulesPath  = [System.IO.Path]::GetTempFileName() + '.json'
    $testGroupsPath = [System.IO.Path]::GetTempFileName() + '.json'
}

AfterEach {
    if (Test-Path -LiteralPath $testRulesPath) {
        Remove-Item -LiteralPath $testRulesPath -Force
    }
    if (Test-Path -LiteralPath $testGroupsPath) {
        Remove-Item -LiteralPath $testGroupsPath -Force
    }
}

Describe 'Add-HvDRSAffinityRule' {

    It 'creates a VmVmAffinity rule and persists it' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Aff1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath

        $rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER1' -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'Aff1'
        $rules[0].Type | Should -Be 'VmVmAffinity'
    }

    It 'stores ClusterName on the rule object' {
        Add-HvDRSAffinityRule -ClusterName 'PROD-CLUSTER' -Name 'R1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.ClusterName | Should -Be 'PROD-CLUSTER'
    }

    It 'generates a non-empty GUID for RuleId' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAntiAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.RuleId | Should -Not -BeNullOrEmpty
        { [System.Guid]::Parse($rule.RuleId) } | Should -Not -Throw
    }

    It 'sets Enforced=$false by default' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Soft' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Enforced | Should -BeFalse
    }

    It 'sets Enforced=$true when -Enforced switch is provided' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Hard' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -Enforced -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Enforced | Should -BeTrue
    }

    It 'throws when VmVmAffinity has fewer than 2 VMs' {
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Bad' -Type 'VmVmAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'throws when VmHostAffinity has no -Hosts' {
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Bad' -Type 'VmHostAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'warns and does not duplicate when the same name exists in the same cluster' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Dup' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Dup' -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath -WarningAction SilentlyContinue

        $rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER1' -RulesPath $testRulesPath
        $rules.Count | Should -Be 1
    }

    It 'allows the same name in two different clusters' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'DC-Anti' -Type 'VmVmAntiAffinity' `
                              -VMs @('DC1','DC2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER2' -Name 'DC-Anti' -Type 'VmVmAntiAffinity' `
                              -VMs @('DC3','DC4') -RulesPath $testRulesPath

        $all = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $all.Count | Should -Be 2
    }

    It 'stores multiple rules for the same cluster' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R2' -Type 'VmVmAntiAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath

        $rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER1' -RulesPath $testRulesPath
        $rules.Count | Should -Be 2
    }

    It 'supports -WhatIf without writing any file' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'WI' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -WhatIf -RulesPath $testRulesPath
        Test-Path -LiteralPath $testRulesPath | Should -BeFalse
    }
}

Describe 'Add-HvDRSAffinityRule — storage rule types' {

    It 'creates a VmVmCsvAffinity rule and persists it' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'CsvAff' -Type 'VmVmCsvAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Type | Should -Be 'VmVmCsvAffinity'
    }

    It 'creates a VmCsvAffinity rule with -CSVs and persists it' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'TierOne' -Type 'VmCsvAffinity' `
                              -VMs @('VM1') -CSVs @('Volume1','Volume2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Type    | Should -Be 'VmCsvAffinity'
        $rule.CSVs    | Should -Contain 'Volume1'
        $rule.CSVs    | Should -Contain 'Volume2'
    }

    It 'throws when VmVmCsvAffinity has fewer than 2 VMs' {
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Bad' -Type 'VmVmCsvAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'throws when VmCsvAntiAffinity has no -CSVs' {
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Bad' -Type 'VmCsvAntiAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'defaults CSVs to an empty array for non-storage rule types' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'HostRule' -Type 'VmHostAffinity' `
                              -VMs @('VM1') -Hosts @('NODE1') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        @($rule.CSVs).Count | Should -Be 0
    }
}

Describe 'Get-HvDRSAffinityRule' {

    BeforeEach {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'AppAffinity' -Type 'VmVmAffinity' `
                              -VMs @('APP1','APP2') -Enforced -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'DC-Anti'     -Type 'VmVmAntiAffinity' `
                              -VMs @('DC1','DC2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'SQL-Host'    -Type 'VmHostAffinity' `
                              -VMs @('SQL1') -Hosts @('NODE1') -RulesPath $testRulesPath
    }

    It 'returns all rules across all clusters when -ClusterName is omitted' {
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 3
    }

    It 'returns only the specified cluster rules when -ClusterName is provided' {
        # Add a rule for a second cluster; it should not appear in CLUSTER1 results
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER2' -Name 'OtherRule' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath

        $rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER1' -RulesPath $testRulesPath
        $rules.Count | Should -Be 3
        $rules.ClusterName | Should -Not -Contain 'CLUSTER2'
    }

    It 'filters by exact Name using ByName parameter set' {
        $rules = Get-HvDRSAffinityRule -Name 'DC-Anti' -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'DC-Anti'
    }

    It 'supports wildcards in Name' {
        # -Name filters on the rule's Name field, not its Type — only 'AppAffinity' matches
        $rules = Get-HvDRSAffinityRule -Name '*Affinity*' -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'AppAffinity'
    }

    It 'filters by Type' {
        $rules = Get-HvDRSAffinityRule -Type 'VmVmAntiAffinity' -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'DC-Anti'
    }

    It 'filters by VmName' {
        $rules = Get-HvDRSAffinityRule -VmName 'SQL1' -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'SQL-Host'
    }

    It 'filters by RuleId' {
        $all  = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $id   = $all[0].RuleId
        $rule = Get-HvDRSAffinityRule -RuleId $id -RulesPath $testRulesPath
        $rule.RuleId | Should -Be $id
    }

    It 'returns empty array when no rules match' {
        $rules = Get-HvDRSAffinityRule -Name 'NonExistent' -RulesPath $testRulesPath
        @($rules).Count | Should -Be 0
    }
}

Describe 'Remove-HvDRSAffinityRule' {

    BeforeEach {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'ToRemove' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'Keep'     -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath
    }

    It 'removes a rule by Name' {
        Remove-HvDRSAffinityRule -Name 'ToRemove' -RulesPath $testRulesPath
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count   | Should -Be 1
        $rules[0].Name | Should -Be 'Keep'
    }

    It 'removes a rule by RuleId' {
        $target = Get-HvDRSAffinityRule -Name 'ToRemove' -RulesPath $testRulesPath
        Remove-HvDRSAffinityRule -RuleId $target.RuleId -RulesPath $testRulesPath
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 1
    }

    It 'only removes from the specified cluster when -ClusterName is given' {
        # Same rule name in a second cluster; remove should only touch CLUSTER1
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER2' -Name 'ToRemove' -Type 'VmVmAffinity' `
                              -VMs @('VM5','VM6') -RulesPath $testRulesPath

        Remove-HvDRSAffinityRule -Name 'ToRemove' -ClusterName 'CLUSTER1' -RulesPath $testRulesPath

        $cluster1Rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER1' -RulesPath $testRulesPath
        $cluster2Rules = Get-HvDRSAffinityRule -ClusterName 'CLUSTER2' -RulesPath $testRulesPath
        $cluster1Rules.Count | Should -Be 1   # 'Keep' remains
        $cluster2Rules.Count | Should -Be 1   # CLUSTER2 rule untouched
    }

    It 'warns without removing when rule name does not exist' {
        { Remove-HvDRSAffinityRule -Name 'NoSuchRule' `
              -RulesPath $testRulesPath -WarningAction SilentlyContinue } | Should -Not -Throw
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 2
    }

    It 'supports -WhatIf without removing' {
        Remove-HvDRSAffinityRule -Name 'ToRemove' -WhatIf -RulesPath $testRulesPath
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 2
    }
}

Describe 'Set-HvDRSAffinityRule' {

    BeforeEach {
        # 3 VMs so removing one still satisfies the VmVmAffinity 2-VM minimum
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'EditMe' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2','VM3') -Description 'Original' `
                              -RulesPath $testRulesPath
        $script:ruleId = (Get-HvDRSAffinityRule -Name 'EditMe' -RulesPath $testRulesPath).RuleId
    }

    It 'renames a rule with -NewName' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -NewName 'Renamed' -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Name | Should -Be 'Renamed'
    }

    It 'updates Description' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -Description 'New description' -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Description | Should -Be 'New description'
    }

    It 'sets Enforced to $true' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -Enforced $true -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Enforced | Should -BeTrue
    }

    It 'adds VMs via -AddVMs without duplicating existing members' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -AddVMs @('VM2','VM3') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.VMs | Should -Contain 'VM3'
        @($rule.VMs | Where-Object { $_ -eq 'VM2' }).Count | Should -Be 1
    }

    It 'removes VMs via -RemoveVMs' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -RemoveVMs @('VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.VMs | Should -Not -Contain 'VM2'
        $rule.VMs | Should -Contain 'VM1'
    }

    It 'throws when RemoveVMs would leave fewer than 2 VMs for a VmVm rule' {
        { Set-HvDRSAffinityRule -RuleId $script:ruleId -RemoveVMs @('VM1','VM2') `
              -RulesPath $testRulesPath } | Should -Throw
    }

    It 'warns and does nothing when RuleId is not found' {
        { Set-HvDRSAffinityRule -RuleId 'nonexistent-guid' -Description 'X' `
              -RulesPath $testRulesPath -WarningAction SilentlyContinue } | Should -Not -Throw
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Description | Should -Be 'Original'
    }

    It 'supports -WhatIf without persisting changes' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -NewName 'ShouldNotSave' `
                              -WhatIf -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Name | Should -Be 'EditMe'
    }

    It 'preserves ClusterName on the rule after editing' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -Description 'Updated' -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.ClusterName | Should -Be 'CLUSTER1'
    }
}

Describe 'Set-HvDRSAffinityRule — storage CSV list' {

    BeforeEach {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'CsvRule' -Type 'VmCsvAffinity' `
                              -VMs @('VM1') -CSVs @('Volume1') -RulesPath $testRulesPath
        $script:csvRuleId = (Get-HvDRSAffinityRule -Name 'CsvRule' -RulesPath $testRulesPath).RuleId
    }

    It 'adds CSVs via -AddCSVs without duplicating existing members' {
        Set-HvDRSAffinityRule -RuleId $script:csvRuleId -AddCSVs @('Volume1','Volume2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.CSVs | Should -Contain 'Volume2'
        @($rule.CSVs | Where-Object { $_ -eq 'Volume1' }).Count | Should -Be 1
    }

    It 'removes CSVs via -RemoveCSVs' {
        Set-HvDRSAffinityRule -RuleId $script:csvRuleId -AddCSVs @('Volume2') -RulesPath $testRulesPath
        Set-HvDRSAffinityRule -RuleId $script:csvRuleId -RemoveCSVs @('Volume1') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.CSVs | Should -Not -Contain 'Volume1'
        $rule.CSVs | Should -Contain 'Volume2'
    }

    It 'throws when RemoveCSVs would leave zero CSVs for a VmCsv rule' {
        { Set-HvDRSAffinityRule -RuleId $script:csvRuleId -RemoveCSVs @('Volume1') `
              -RulesPath $testRulesPath } | Should -Throw
    }
}

Describe 'Per-cluster scoping' {

    It 'rules for different clusters coexist in the same file without interference' {
        Add-HvDRSAffinityRule -ClusterName 'PROD' -Name 'Rule-A' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'DEV'  -Name 'Rule-B' -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'DEV'  -Name 'Rule-C' -Type 'VmVmAntiAffinity' `
                              -VMs @('VM5','VM6') -RulesPath $testRulesPath

        $prod = Get-HvDRSAffinityRule -ClusterName 'PROD' -RulesPath $testRulesPath
        $dev  = Get-HvDRSAffinityRule -ClusterName 'DEV'  -RulesPath $testRulesPath
        $all  = Get-HvDRSAffinityRule                     -RulesPath $testRulesPath

        $prod.Count | Should -Be 1
        $dev.Count  | Should -Be 2
        $all.Count  | Should -Be 3
    }

    It 'removing a rule from one cluster does not affect another cluster' {
        Add-HvDRSAffinityRule -ClusterName 'PROD' -Name 'Shared-Name' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'DEV'  -Name 'Shared-Name' -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath

        Remove-HvDRSAffinityRule -Name 'Shared-Name' -ClusterName 'PROD' -RulesPath $testRulesPath

        $prod = Get-HvDRSAffinityRule -ClusterName 'PROD' -RulesPath $testRulesPath
        $dev  = Get-HvDRSAffinityRule -ClusterName 'DEV'  -RulesPath $testRulesPath
        $prod.Count | Should -Be 0
        $dev.Count  | Should -Be 1
    }

    It 'Get-AffinityRuleSet with ClusterName returns only that cluster (private function)' {
        Add-HvDRSAffinityRule -ClusterName 'PROD' -Name 'P1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -ClusterName 'DEV'  -Name 'D1' -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath

        $prodRules = Get-AffinityRuleSet -ClusterName 'PROD' -Path $testRulesPath
        $prodRules.Count             | Should -Be 1
        $prodRules[0].ClusterName    | Should -Be 'PROD'
    }
}

Describe 'Group expansion in Get-AffinityRuleSet' {

    It 'unions a VM group''s members into a rule''s VMs at read time' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'SQL VMs' -Type Vm -Members @('SQL1','SQL2') -GroupsPath $testGroupsPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAntiAffinity' `
                              -VMs @('DC1') -VMGroups @('SQL VMs') -RulesPath $testRulesPath

        $rule = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        $rule[0].VMs | Should -Contain 'DC1'
        $rule[0].VMs | Should -Contain 'SQL1'
        $rule[0].VMs | Should -Contain 'SQL2'
    }

    It 'reflects a group membership change immediately, with no rule re-save' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'WebVMs' -Type Vm -Members @('WEB1') -GroupsPath $testGroupsPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAffinity' `
                              -VMs @('LB1') -VMGroups @('WebVMs') -RulesPath $testRulesPath

        $before = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        $before[0].VMs.Count | Should -Be 2

        $group = Get-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'WebVMs' -GroupsPath $testGroupsPath
        Set-HvDRSGroup -GroupId $group.GroupId -AddMembers @('WEB2') -GroupsPath $testGroupsPath

        $after = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        $after[0].VMs.Count | Should -Be 3
        $after[0].VMs | Should -Contain 'WEB2'
    }

    It 'expands host groups into a VmHostAffinity rule''s Hosts' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'Rack A' -Type Host -Members @('NODE1','NODE2') -GroupsPath $testGroupsPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmHostAffinity' `
                              -VMs @('VM1') -HostGroups @('Rack A') -RulesPath $testRulesPath

        $rule = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        $rule[0].Hosts | Should -Contain 'NODE1'
        $rule[0].Hosts | Should -Contain 'NODE2'
    }

    It 'expands CSV groups into a VmCsvAffinity rule''s CSVs' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'Tier1' -Type Csv -Members @('Volume1','Volume2') -GroupsPath $testGroupsPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmCsvAffinity' `
                              -VMs @('VM1') -CSVGroups @('Tier1') -RulesPath $testRulesPath

        $rule = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        $rule[0].CSVs | Should -Contain 'Volume1'
        $rule[0].CSVs | Should -Contain 'Volume2'
    }

    It 'does not persist expanded group members back into the rule store on a subsequent edit' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'SQL VMs' -Type Vm -Members @('SQL1','SQL2') -GroupsPath $testGroupsPath
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAntiAffinity' `
                              -VMs @('DC1') -VMGroups @('SQL VMs') -RulesPath $testRulesPath

        # Trigger a resave via Set-HvDRSAffinityRule (loads raw, unexpanded rules internally)
        $rule = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath $testGroupsPath
        Set-HvDRSAffinityRule -RuleId $rule[0].RuleId -Description 'updated' -RulesPath $testRulesPath

        # Raw (unexpanded) rule on disk must still show only the literal VM, not the group's members
        $raw = Get-Content -LiteralPath $testRulesPath -Raw | ConvertFrom-Json
        @($raw.Rules[0].VMs) | Should -Be @('DC1')
    }

    It 'works when groups.json does not exist (no groups defined)' {
        Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath

        $rule = Get-AffinityRuleSet -ClusterName 'CLUSTER1' -Path $testRulesPath -GroupsPath 'TestDrive:\does-not-exist.json'
        $rule[0].VMs | Should -Be @('VM1','VM2')
    }

    It 'validates minimum VM membership counting VMGroups alongside VMs' {
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R1' -Type 'VmVmAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } | Should -Throw
        { Add-HvDRSAffinityRule -ClusterName 'CLUSTER1' -Name 'R2' -Type 'VmVmAffinity' `
                                -VMs @('VM1') -VMGroups @('SomeGroup') -RulesPath $testRulesPath } | Should -Not -Throw
    }
}

}
