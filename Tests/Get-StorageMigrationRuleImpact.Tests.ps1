#Requires -Module Pester
<#
    Unit tests for Get-StorageMigrationRuleImpact.
    No FailoverClusters or Hyper-V modules are required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-StorageMigrationRuleImpact.ps1"

    # Builds a minimal storage snapshot with 3 CSVs and the VMs supplied
    function New-ImpactStorageSnapshot {
        param([PSCustomObject[]]$VMs)
        New-StorageSnapshot -CSVs @(
            New-CsvMetrics -Name 'Volume1' -Path 'C:\ClusterStorage\Volume1'
            New-CsvMetrics -Name 'Volume2' -Path 'C:\ClusterStorage\Volume2'
            New-CsvMetrics -Name 'Volume3' -Path 'C:\ClusterStorage\Volume3'
        ) -VMs $VMs
    }

    function New-VmVmCsvAffinityRule {
        param([string]$Name = 'CsvAff', [string[]]$VMs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r1'; Name=$Name; Type='VmVmCsvAffinity';
                           Enforced=$Enforced; VMs=$VMs; CSVs=@() }
    }
    function New-VmVmCsvAntiAffinityRule {
        param([string]$Name = 'CsvAnti', [string[]]$VMs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r2'; Name=$Name; Type='VmVmCsvAntiAffinity';
                           Enforced=$Enforced; VMs=$VMs; CSVs=@() }
    }
    function New-VmCsvAffinityRule {
        param([string]$Name = 'CsvPlaceAff', [string[]]$VMs, [string[]]$CSVs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r3'; Name=$Name; Type='VmCsvAffinity';
                           Enforced=$Enforced; VMs=$VMs; CSVs=$CSVs }
    }
    function New-VmCsvAntiAffinityRule {
        param([string]$Name = 'CsvPlaceAnti', [string[]]$VMs, [string[]]$CSVs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r4'; Name=$Name; Type='VmCsvAntiAffinity';
                           Enforced=$Enforced; VMs=$VMs; CSVs=$CSVs }
    }
}

Describe 'Get-StorageMigrationRuleImpact — empty / no-op cases' {

    It 'returns all-false when RuleSet is empty' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @()
        $result.HasHardViolation | Should -BeFalse
        $result.HasSoftViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }

    It 'returns all-false when RuleSet is null' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet $null
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }

    It 'returns all-false when no rule references the migrating VM' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule   = New-VmVmCsvAffinityRule -VMs @('VM2','VM3')   # VM1 not in rule
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-StorageMigrationRuleImpact — VmVmCsvAffinity' {

    It 'detects a hard violation when moving VM off shared CSV' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume1'
        )
        $rule   = New-VmVmCsvAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation  | Should -BeTrue
        $result.FixesViolation    | Should -BeFalse
        $result.HardReasons.Count | Should -BeGreaterThan 0
    }

    It 'detects a soft violation when breaking a non-enforced storage affinity rule' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume1'
        )
        $rule   = New-VmVmCsvAffinityRule -VMs @('VM1','VM2') -Enforced $false
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.HasSoftViolation | Should -BeTrue
    }

    It 'reports FixesViolation when consolidating a split affinity group' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule   = New-VmVmCsvAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
        $result.FixReasons.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-StorageMigrationRuleImpact — VmVmCsvAntiAffinity' {

    It 'detects a hard violation when moving VM onto a CSV already used by a peer' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume2'
        )
        $rule   = New-VmVmCsvAntiAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
        $result.FixesViolation   | Should -BeFalse
    }

    It 'reports FixesViolation when separating co-located VM storage' {
        $snap = New-ImpactStorageSnapshot @(
            New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1'
            New-VmStorageMetrics -Name 'VM2' -PrimaryCSV 'C:\ClusterStorage\Volume1'
        )
        $rule   = New-VmVmCsvAntiAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }
}

Describe 'Get-StorageMigrationRuleImpact — VmCsvAffinity' {

    It 'detects a hard violation when moving VM off allowed CSVs' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $rule   = New-VmCsvAffinityRule -VMs @('VM1') -CSVs @('Volume1','Volume2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume3' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
    }

    It 'reports FixesViolation when moving VM onto an allowed CSV' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume3')
        $rule   = New-VmCsvAffinityRule -VMs @('VM1') -CSVs @('Volume1','Volume2') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume1' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }
}

Describe 'Get-StorageMigrationRuleImpact — VmCsvAntiAffinity' {

    It 'detects a hard violation when moving VM onto an excluded CSV' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $rule   = New-VmCsvAntiAffinityRule -VMs @('VM1') -CSVs @('Volume2','Volume3') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
    }

    It 'reports FixesViolation when moving VM off an excluded CSV' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume2')
        $rule   = New-VmCsvAntiAffinityRule -VMs @('VM1') -CSVs @('Volume2','Volume3') -Enforced $true
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume1' `
                                                  -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }
}

Describe 'Get-StorageMigrationRuleImpact — output object structure' {

    It 'always returns an object with all 6 expected properties' {
        $snap   = New-ImpactStorageSnapshot @(New-VmStorageMetrics -Name 'VM1' -PrimaryCSV 'C:\ClusterStorage\Volume1')
        $result = Get-StorageMigrationRuleImpact -VMName 'VM1' -DestinationCsvName 'Volume2' `
                                                  -Snapshot $snap -RuleSet @()
        $props = $result.PSObject.Properties.Name
        $props | Should -Contain 'HasHardViolation'
        $props | Should -Contain 'HasSoftViolation'
        $props | Should -Contain 'FixesViolation'
        $props | Should -Contain 'HardReasons'
        $props | Should -Contain 'SoftReasons'
        $props | Should -Contain 'FixReasons'
    }
}
