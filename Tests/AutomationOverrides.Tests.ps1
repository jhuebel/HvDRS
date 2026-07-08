#Requires -Module Pester
<#
    Unit tests for the public per-VM automation-level override functions:
        Set-HvDRSVMAutomationLevel
        Get-HvDRSVMAutomationLevel
        Remove-HvDRSVMAutomationLevel

    All tests use a per-test temporary file so they never touch the real override
    store at $env:ProgramData\HvDRS\automation-overrides.json.
#>

Describe 'AutomationOverrides' {

BeforeAll {
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSDataRoot.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSAutomationOverrideSet.ps1"
    . "$PSScriptRoot/../Functions/Public/AutomationOverrides.ps1"
}

BeforeEach {
    $testOverridesPath = [System.IO.Path]::GetTempFileName() + '.json'
}

AfterEach {
    if (Test-Path -LiteralPath $testOverridesPath) {
        Remove-Item -LiteralPath $testOverridesPath -Force
    }
}

Describe 'Set-HvDRSVMAutomationLevel' {

    It 'creates a new Manual override' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath

        $override = Get-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath
        $override[0].AutomationLevel | Should -Be 'Manual'
    }

    It 'stores an optional Reason' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -Reason 'Change window' -OverridesPath $testOverridesPath

        $override = Get-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath
        $override[0].Reason | Should -Be 'Change window'
    }

    It 'updates (upserts) an existing override rather than duplicating it' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel FullyAutomated -OverridesPath $testOverridesPath

        $all = Get-HvDRSVMAutomationLevel -ClusterName 'C1' -OverridesPath $testOverridesPath
        $all.Count | Should -Be 1
        $all[0].AutomationLevel | Should -Be 'FullyAutomated'
    }

    It 'scopes overrides per cluster — same VM name in a different cluster is independent' {
        Set-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Set-HvDRSVMAutomationLevel -ClusterName 'DEV'  -VMName 'VM1' -AutomationLevel FullyAutomated -OverridesPath $testOverridesPath

        (Get-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM1' -OverridesPath $testOverridesPath)[0].AutomationLevel | Should -Be 'Manual'
        (Get-HvDRSVMAutomationLevel -ClusterName 'DEV'  -VMName 'VM1' -OverridesPath $testOverridesPath)[0].AutomationLevel | Should -Be 'FullyAutomated'
    }

    It '-WhatIf does not create the file' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath -WhatIf
        Test-Path -LiteralPath $testOverridesPath | Should -BeFalse
    }
}

Describe 'Get-HvDRSVMAutomationLevel' {

    BeforeEach {
        Set-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Set-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM2' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Set-HvDRSVMAutomationLevel -ClusterName 'DEV'  -VMName 'VM3' -AutomationLevel Manual -OverridesPath $testOverridesPath
    }

    It 'returns all overrides across all clusters when -ClusterName is omitted' {
        $all = Get-HvDRSVMAutomationLevel -OverridesPath $testOverridesPath
        $all.Count | Should -Be 3
    }

    It 'returns only the specified cluster''s overrides' {
        $prod = Get-HvDRSVMAutomationLevel -ClusterName 'PROD' -OverridesPath $testOverridesPath
        $prod.Count | Should -Be 2
    }

    It 'filters to a single VM' {
        $vm = Get-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM2' -OverridesPath $testOverridesPath
        $vm.Count | Should -Be 1
        $vm[0].VMName | Should -Be 'VM2'
    }

    It 'returns an empty array (not $null) when no override exists for a VM' {
        $vm = Get-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'NoSuchVM' -OverridesPath $testOverridesPath
        ($null -eq $vm) | Should -BeFalse
        @($vm).Count | Should -Be 0
    }
}

Describe 'Remove-HvDRSVMAutomationLevel' {

    It 'removes an existing override' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Remove-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath

        (Get-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath).Count | Should -Be 0
    }

    It 'does not affect the same VM name in a different cluster' {
        Set-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Set-HvDRSVMAutomationLevel -ClusterName 'DEV'  -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath

        Remove-HvDRSVMAutomationLevel -ClusterName 'PROD' -VMName 'VM1' -OverridesPath $testOverridesPath

        (Get-HvDRSVMAutomationLevel -ClusterName 'PROD' -OverridesPath $testOverridesPath).Count | Should -Be 0
        (Get-HvDRSVMAutomationLevel -ClusterName 'DEV'  -OverridesPath $testOverridesPath).Count | Should -Be 1
    }

    It 'warns and does nothing when no override exists' {
        Remove-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'NoSuchVM' -OverridesPath $testOverridesPath -WarningAction SilentlyContinue
    }

    It '-WhatIf does not remove the override' {
        Set-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -AutomationLevel Manual -OverridesPath $testOverridesPath
        Remove-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath -WhatIf

        (Get-HvDRSVMAutomationLevel -ClusterName 'C1' -VMName 'VM1' -OverridesPath $testOverridesPath).Count | Should -Be 1
    }
}

}
