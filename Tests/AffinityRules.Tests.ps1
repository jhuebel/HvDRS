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

BeforeAll {
    . "$PSScriptRoot/../Functions/Private/Get-AffinityRuleSet.ps1"
    . "$PSScriptRoot/../Functions/Public/AffinityRules.ps1"
}

# Each test gets its own temp file path via BeforeEach / AfterEach
BeforeEach {
    $testRulesPath = [System.IO.Path]::GetTempFileName() + '.json'
}

AfterEach {
    if (Test-Path -LiteralPath $testRulesPath) {
        Remove-Item -LiteralPath $testRulesPath -Force
    }
}

Describe 'Add-HvDRSAffinityRule' {

    It 'creates a VmVmAffinity rule and persists it' {
        Add-HvDRSAffinityRule -Name 'Aff1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath

        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count    | Should -Be 1
        $rules[0].Name  | Should -Be 'Aff1'
        $rules[0].Type  | Should -Be 'VmVmAffinity'
    }

    It 'generates a non-empty GUID for RuleId' {
        Add-HvDRSAffinityRule -Name 'R1' -Type 'VmVmAntiAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.RuleId | Should -Not -BeNullOrEmpty
        { [System.Guid]::Parse($rule.RuleId) } | Should -Not -Throw
    }

    It 'sets Enforced=$false by default' {
        Add-HvDRSAffinityRule -Name 'Soft' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Enforced | Should -BeFalse
    }

    It 'sets Enforced=$true when -Enforced switch is provided' {
        Add-HvDRSAffinityRule -Name 'Hard' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -Enforced -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Enforced | Should -BeTrue
    }

    It 'throws when VmVmAffinity has fewer than 2 VMs' {
        { Add-HvDRSAffinityRule -Name 'Bad' -Type 'VmVmAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'throws when VmHostAffinity has no -Hosts' {
        { Add-HvDRSAffinityRule -Name 'Bad' -Type 'VmHostAffinity' `
                                -VMs @('VM1') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'warns and does not duplicate when a rule with the same name exists' {
        Add-HvDRSAffinityRule -Name 'Dup' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -Name 'Dup' -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath -WarningAction SilentlyContinue

        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 1
    }

    It 'stores multiple rules' {
        Add-HvDRSAffinityRule -Name 'R1' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -Name 'R2' -Type 'VmVmAntiAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath

        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 2
    }

    It 'supports -WhatIf without writing any file' {
        Add-HvDRSAffinityRule -Name 'WI' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -WhatIf -RulesPath $testRulesPath
        Test-Path -LiteralPath $testRulesPath | Should -BeFalse
    }
}

Describe 'Get-HvDRSAffinityRule' {

    BeforeEach {
        Add-HvDRSAffinityRule -Name 'AppAffinity'  -Type 'VmVmAffinity'       `
                              -VMs @('APP1','APP2') -Enforced -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -Name 'DC-Anti'      -Type 'VmVmAntiAffinity'   `
                              -VMs @('DC1','DC2')   -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -Name 'SQL-Host'     -Type 'VmHostAffinity'     `
                              -VMs @('SQL1') -Hosts @('NODE1') -RulesPath $testRulesPath
    }

    It 'returns all rules by default' {
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 3
    }

    It 'filters by exact Name using ByName parameter set' {
        $rules = Get-HvDRSAffinityRule -Name 'DC-Anti' -RulesPath $testRulesPath
        $rules.Count    | Should -Be 1
        $rules[0].Name  | Should -Be 'DC-Anti'
    }

    It 'supports wildcards in Name' {
        $rules = Get-HvDRSAffinityRule -Name '*Affinity*' -RulesPath $testRulesPath
        $rules.Count | Should -Be 2  # AppAffinity + VmHostAffinity's SQL-Host actually doesn't match — just AppAffinity
    }

    It 'filters by Type' {
        $rules = Get-HvDRSAffinityRule -Type 'VmVmAntiAffinity' -RulesPath $testRulesPath
        $rules.Count    | Should -Be 1
        $rules[0].Name  | Should -Be 'DC-Anti'
    }

    It 'filters by VmName' {
        $rules = Get-HvDRSAffinityRule -VmName 'SQL1' -RulesPath $testRulesPath
        $rules.Count | Should -Be 1
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
        Add-HvDRSAffinityRule -Name 'ToRemove' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -RulesPath $testRulesPath
        Add-HvDRSAffinityRule -Name 'Keep'     -Type 'VmVmAffinity' `
                              -VMs @('VM3','VM4') -RulesPath $testRulesPath
    }

    It 'removes a rule by Name' {
        Remove-HvDRSAffinityRule -Name 'ToRemove' -RulesPath $testRulesPath
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count    | Should -Be 1
        $rules[0].Name  | Should -Be 'Keep'
    }

    It 'removes a rule by RuleId' {
        $target = Get-HvDRSAffinityRule -Name 'ToRemove' -RulesPath $testRulesPath
        Remove-HvDRSAffinityRule -RuleId $target.RuleId -RulesPath $testRulesPath
        $rules = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rules.Count | Should -Be 1
    }

    It 'warns without removing when rule name does not exist' {
        { Remove-HvDRSAffinityRule -Name 'NoSuchRule' -RulesPath $testRulesPath -WarningAction SilentlyContinue } |
            Should -Not -Throw
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
        Add-HvDRSAffinityRule -Name 'EditMe' -Type 'VmVmAffinity' `
                              -VMs @('VM1','VM2') -Description 'Original' `
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
        ($rule.VMs | Where-Object { $_ -eq 'VM2' }).Count | Should -Be 1   # no duplicate
    }

    It 'removes VMs via -RemoveVMs' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -RemoveVMs @('VM2') -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.VMs | Should -Not -Contain 'VM2'
        $rule.VMs | Should -Contain 'VM1'
    }

    It 'throws when RemoveVMs would leave fewer than 2 VMs for a VmVm rule' {
        { Set-HvDRSAffinityRule -RuleId $script:ruleId -RemoveVMs @('VM1','VM2') -RulesPath $testRulesPath } |
            Should -Throw
    }

    It 'warns and does nothing when RuleId is not found' {
        { Set-HvDRSAffinityRule -RuleId 'nonexistent-guid' -Description 'X' `
                                -RulesPath $testRulesPath -WarningAction SilentlyContinue } |
            Should -Not -Throw
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Description | Should -Be 'Original'
    }

    It 'supports -WhatIf without persisting changes' {
        Set-HvDRSAffinityRule -RuleId $script:ruleId -NewName 'ShouldNotSave' `
                              -WhatIf -RulesPath $testRulesPath
        $rule = Get-HvDRSAffinityRule -RulesPath $testRulesPath
        $rule.Name | Should -Be 'EditMe'
    }
}
