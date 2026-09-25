#Requires -Module Pester
<#
    Unit tests for the public "collect a live snapshot and check compliance"
    wrapper functions:
        Test-HvDRSAffinityCompliance
        Test-HvDRSStorageAffinityCompliance

    Get-ClusterSnapshot / Get-StorageSnapshot are mocked out entirely so these
    tests exercise only the wrappers' own control flow (rule loading, snapshot
    collection, formatting, return value) without needing a real cluster.
    No FailoverClusters or Hyper-V modules are required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"

    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-ClusterSnapshot { param($ClusterName, $SampleCount, $SampleIntervalSeconds) }
    function Get-StorageSnapshot { param($ClusterName, $SampleCount) }

    . "$PSScriptRoot/../Functions/Private/Get-AffinityRuleSet.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSGroupSet.ps1"
    . "$PSScriptRoot/../Functions/Private/Test-AffinityCompliance.ps1"
    . "$PSScriptRoot/../Functions/Private/Test-StorageAffinityCompliance.ps1"
    . "$PSScriptRoot/../Functions/Public/AffinityRules.ps1"
}

Describe 'Test-HvDRSAffinityCompliance' {

    BeforeEach {
        $testRulesPath = [System.IO.Path]::GetTempFileName() + '.json'
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRulesPath) { Remove-Item -LiteralPath $testRulesPath -Force }
    }

    It 'returns only violation objects — no Format-Table output leaks into the return value' {
        Add-HvDRSAffinityRule -ClusterName 'TEST-CLUSTER' -Name 'DC AA' -Type VmVmAntiAffinity `
                              -VMs @('DC1', 'DC2') -Enforced -RulesPath $testRulesPath

        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(
                (New-VmMetrics -Name 'DC1' -HostNode 'NODE1'),
                (New-VmMetrics -Name 'DC2' -HostNode 'NODE1')
            )
        }

        $result = Test-HvDRSAffinityCompliance -ClusterName 'TEST-CLUSTER' -RulesPath $testRulesPath 6>$null

        # Without the `| Out-Host` fix, Format-Table's own stream objects
        # (FormatStartData, GroupStartData, one FormatEntryData per row, ...)
        # would be emitted ahead of the real violation in the function's return
        # value, inflating the count and making the first element a format
        # object rather than the violation itself.
        @($result).Count | Should -Be 1
        $result[0] | Should -BeOfType ([PSCustomObject])
        $result[0].PSObject.TypeNames | Should -Not -Contain 'Microsoft.PowerShell.Commands.Internal.Format.FormatStartData'
        $result.RuleName | Should -Be 'DC AA'
    }

    It 'returns an empty array (not $null) when every rule is satisfied' {
        Add-HvDRSAffinityRule -ClusterName 'TEST-CLUSTER' -Name 'DC AA' -Type VmVmAntiAffinity `
                              -VMs @('DC1', 'DC2') -Enforced -RulesPath $testRulesPath

        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1', New-HostMetrics -Name 'NODE2') -VMs @(
                (New-VmMetrics -Name 'DC1' -HostNode 'NODE1'),
                (New-VmMetrics -Name 'DC2' -HostNode 'NODE2')
            )
        }

        $result = @(Test-HvDRSAffinityCompliance -ClusterName 'TEST-CLUSTER' -RulesPath $testRulesPath 6>$null)
        $result.Count | Should -Be 0
    }

    It 'returns an empty array without collecting a snapshot when no rules are configured' {
        Mock Get-ClusterSnapshot { throw 'should not be called when there are no rules' }

        $result = @(Test-HvDRSAffinityCompliance -ClusterName 'TEST-CLUSTER' -RulesPath $testRulesPath 6>$null)
        $result.Count | Should -Be 0
        Should -Invoke Get-ClusterSnapshot -Times 0
    }
}

Describe 'Test-HvDRSStorageAffinityCompliance' {

    BeforeEach {
        $testRulesPath = [System.IO.Path]::GetTempFileName() + '.json'
    }

    AfterEach {
        if (Test-Path -LiteralPath $testRulesPath) { Remove-Item -LiteralPath $testRulesPath -Force }
    }

    It 'returns only violation objects — no Format-Table output leaks into the return value' {
        Add-HvDRSAffinityRule -ClusterName 'TEST-CLUSTER' -Name 'NoVol1' -Type VmCsvAntiAffinity `
                              -VMs @('VM1') -CSVs @('Volume1') -Enforced -RulesPath $testRulesPath

        Mock Get-StorageSnapshot {
            New-StorageSnapshot -CSVs @(New-CsvMetrics -Name 'Volume1' -Path 'C:\ClusterStorage\Volume1') `
                                -VMs @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        }

        $result = Test-HvDRSStorageAffinityCompliance -ClusterName 'TEST-CLUSTER' -RulesPath $testRulesPath 6>$null

        @($result).Count | Should -Be 1
        $result[0] | Should -BeOfType ([PSCustomObject])
        $result[0].PSObject.TypeNames | Should -Not -Contain 'Microsoft.PowerShell.Commands.Internal.Format.FormatStartData'
        $result.RuleName | Should -Be 'NoVol1'
    }

    It 'returns an empty array without collecting a snapshot when no storage rules are configured' {
        # A non-storage rule exists, but Test-HvDRSStorageAffinityCompliance only
        # acts on the four storage rule types.
        Add-HvDRSAffinityRule -ClusterName 'TEST-CLUSTER' -Name 'DC AA' -Type VmVmAntiAffinity `
                              -VMs @('DC1', 'DC2') -Enforced -RulesPath $testRulesPath

        Mock Get-StorageSnapshot { throw 'should not be called when there are no storage rules' }

        $result = @(Test-HvDRSStorageAffinityCompliance -ClusterName 'TEST-CLUSTER' -RulesPath $testRulesPath 6>$null)
        $result.Count | Should -Be 0
        Should -Invoke Get-StorageSnapshot -Times 0
    }
}
