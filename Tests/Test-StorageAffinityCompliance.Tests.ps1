#Requires -Module Pester
<#
    Unit tests for Test-StorageAffinityCompliance.
    No FailoverClusters or Hyper-V modules are required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Functions/Private/Test-StorageAffinityCompliance.ps1"

    function New-ComplianceStorageSnapshot {
        param([PSCustomObject[]]$VMs)
        New-StorageSnapshot -CSVs @(
            New-CsvMetrics -Name 'Volume1' -Path 'C:\ClusterStorage\Volume1'
            New-CsvMetrics -Name 'Volume2' -Path 'C:\ClusterStorage\Volume2'
            New-CsvMetrics -Name 'Volume3' -Path 'C:\ClusterStorage\Volume3'
        ) -VMs $VMs
    }

    function New-StorageRule {
        param(
            [string]   $Id,
            [string]   $Name,
            [string]   $Type,
            [bool]     $Enforced = $true,
            [string[]] $VMs      = @(),
            [string[]] $CSVs     = @()
        )
        [PSCustomObject]@{ RuleId=$Id; Name=$Name; Type=$Type; Enforced=$Enforced; VMs=$VMs; CSVs=$CSVs }
    }
}

Describe 'Test-StorageAffinityCompliance — no-op cases' {

    It 'returns empty array when RuleSet is empty' {
        $snap   = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @()
        @($result).Count | Should -Be 0
    }

    It 'returns empty array when RuleSet is null' {
        $snap   = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet $null
        @($result).Count | Should -Be 0
    }

    It 'skips rules whose VMs are not in the snapshot' {
        $snap = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $rule = New-StorageRule -Id 'r1' -Name 'Gone' -Type 'VmVmCsvAffinity' -VMs @('VM_GONE1','VM_GONE2')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }
}

Describe 'Test-StorageAffinityCompliance — VmVmCsvAffinity' {

    It 'reports no violation when group shares one CSV' {
        $snap = New-ComplianceStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume1'
        )
        $rule   = New-StorageRule -Id 'r1' -Name 'Aff' -Type 'VmVmCsvAffinity' -VMs @('VM1','VM2')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports one violation when group is split across two CSVs' {
        $snap = New-ComplianceStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule    = New-StorageRule -Id 'r1' -Name 'Aff' -Type 'VmVmCsvAffinity' -VMs @('VM1','VM2')
        $result  = @(Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $result[0].Type     | Should -Be 'VmVmCsvAffinity'
        $result[0].VMs      | Should -Contain 'VM1'
        $result[0].VMs      | Should -Contain 'VM2'
    }
}

Describe 'Test-StorageAffinityCompliance — VmVmCsvAntiAffinity' {

    It 'reports no violation when all VMs are on separate CSVs' {
        $snap = New-ComplianceStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule   = New-StorageRule -Id 'r1' -Name 'Anti' -Type 'VmVmCsvAntiAffinity' -VMs @('VM1','VM2')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports one violation per co-located pair' {
        $snap = New-ComplianceStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM3' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule    = New-StorageRule -Id 'r1' -Name 'Anti' -Type 'VmVmCsvAntiAffinity' -VMs @('VM1','VM2','VM3')
        $result  = @(Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $result[0].VMs | Should -Contain 'VM1'
        $result[0].VMs | Should -Contain 'VM2'
    }
}

Describe 'Test-StorageAffinityCompliance — VmCsvAffinity' {

    It 'reports no violation when VM storage is on an allowed CSV' {
        $snap   = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $rule   = New-StorageRule -Id 'r1' -Name 'CsvAff' -Type 'VmCsvAffinity' `
                                  -VMs @('VM1') -CSVs @('Volume1','Volume2')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports a violation when VM storage is on a non-allowed CSV' {
        $snap = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume3')
        $rule    = New-StorageRule -Id 'r1' -Name 'CsvAff' -Type 'VmCsvAffinity' `
                                   -VMs @('VM1') -CSVs @('Volume1','Volume2')
        $result  = @(Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count          | Should -Be 1
        $result[0].VMs         | Should -Contain 'VM1'
        $result[0].Description | Should -Match 'Volume3'
    }
}

Describe 'Test-StorageAffinityCompliance — VmCsvAntiAffinity' {

    It 'reports no violation when VM storage is not on any excluded CSV' {
        $snap   = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $rule   = New-StorageRule -Id 'r1' -Name 'CsvAnti' -Type 'VmCsvAntiAffinity' `
                                  -VMs @('VM1') -CSVs @('Volume2','Volume3')
        $result = Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports a violation when VM storage is on an excluded CSV' {
        $snap = New-ComplianceStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume2')
        $rule   = New-StorageRule -Id 'r1' -Name 'CsvAnti' -Type 'VmCsvAntiAffinity' `
                                  -VMs @('VM1') -CSVs @('Volume2','Volume3')
        $result = @(Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count          | Should -Be 1
        $result[0].VMs         | Should -Contain 'VM1'
        $result[0].Description | Should -Match 'Volume2'
    }
}

Describe 'Test-StorageAffinityCompliance — output fields' {

    It 'each violation includes RuleId, RuleName, Type, Enforced, VMs, Description' {
        $snap = New-ComplianceStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule    = New-StorageRule -Id 'r99' -Name 'Test Rule' -Type 'VmVmCsvAffinity' `
                                   -Enforced $false -VMs @('VM1','VM2')
        $result  = @(Test-StorageAffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $v = $result[0]
        $v.RuleId      | Should -Be 'r99'
        $v.RuleName    | Should -Be 'Test Rule'
        $v.Type        | Should -Be 'VmVmCsvAffinity'
        $v.Enforced    | Should -BeFalse
        $v.VMs.Count   | Should -BeGreaterThan 0
        $v.Description | Should -Not -BeNullOrEmpty
    }
}
