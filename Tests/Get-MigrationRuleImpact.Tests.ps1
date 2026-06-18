#Requires -Module Pester
<#
    Unit tests for Get-MigrationRuleImpact.
    No FailoverClusters or Hyper-V modules are required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-MigrationRuleImpact.ps1"

    # Builds a minimal snapshot with 3 nodes and the VMs supplied
    function New-ImpactSnapshot {
        param([PSCustomObject[]]$VMs)
        New-Snapshot -Nodes @(
            New-HostMetrics -Name 'NODE1'
            New-HostMetrics -Name 'NODE2'
            New-HostMetrics -Name 'NODE3'
        ) -VMs $VMs
    }

    # Common rule builders
    function New-VmVmAffinityRule {
        param([string]$Name = 'Aff', [string[]]$VMs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r1'; Name=$Name; Type='VmVmAffinity';
                           Enforced=$Enforced; VMs=$VMs; Hosts=@() }
    }
    function New-VmVmAntiAffinityRule {
        param([string]$Name = 'Anti', [string[]]$VMs, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r2'; Name=$Name; Type='VmVmAntiAffinity';
                           Enforced=$Enforced; VMs=$VMs; Hosts=@() }
    }
    function New-VmHostAffinityRule {
        param([string]$Name = 'HostAff', [string[]]$VMs, [string[]]$Hosts, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r3'; Name=$Name; Type='VmHostAffinity';
                           Enforced=$Enforced; VMs=$VMs; Hosts=$Hosts }
    }
    function New-VmHostAntiAffinityRule {
        param([string]$Name = 'HostAnti', [string[]]$VMs, [string[]]$Hosts, [bool]$Enforced = $true)
        [PSCustomObject]@{ RuleId='r4'; Name=$Name; Type='VmHostAntiAffinity';
                           Enforced=$Enforced; VMs=$VMs; Hosts=$Hosts }
    }
}

Describe 'Get-MigrationRuleImpact — empty / no-op cases' {

    It 'returns all-false when RuleSet is empty' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @()
        $result.HasHardViolation | Should -BeFalse
        $result.HasSoftViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }

    It 'returns all-false when RuleSet is null' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet $null
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }

    It 'returns all-false when no rule references the migrating VM' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM2','VM3')   # VM1 not in rule
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-MigrationRuleImpact — VmVmAffinity' {

    It 'detects a hard violation when moving VM off shared host' {
        # VM1 and VM2 already together on NODE1 (rule satisfied)
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
        $result.FixesViolation   | Should -BeFalse
        $result.HardReasons.Count | Should -BeGreaterThan 0
    }

    It 'detects a soft violation when breaking a non-enforced affinity rule' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM1','VM2') -Enforced $false
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.HasSoftViolation | Should -BeTrue
    }

    It 'reports FixesViolation when consolidating a split affinity group' {
        # VM1 on NODE1, VM2 on NODE2 (already violated); moving VM1 to NODE2 fixes it
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
        $result.FixReasons.Count | Should -BeGreaterThan 0
    }

    It 'is neutral when rule is already violated and move does not fix it' {
        # VM1 NODE1, VM2 NODE2; moving VM1 to NODE3 keeps it violated
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE3' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-MigrationRuleImpact — VmVmAntiAffinity' {

    It 'detects a hard violation when moving VM onto a host already running a peer' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAntiAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
        $result.FixesViolation   | Should -BeFalse
    }

    It 'detects a soft violation for a non-enforced anti-affinity rule' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAntiAffinityRule -VMs @('VM1','VM2') -Enforced $false
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.HasSoftViolation | Should -BeTrue
    }

    It 'reports FixesViolation when separating co-located VMs' {
        # Both VMs on NODE1 (rule violated); moving VM1 to NODE2 fixes it
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-VmVmAntiAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }

    It 'is neutral when anti-affinity rule is satisfied and move keeps it satisfied' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-VmVmAntiAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE3' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-MigrationRuleImpact — VmHostAffinity' {

    It 'detects a hard violation when moving VM off allowed hosts' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-VmHostAffinityRule -VMs @('VM1') -Hosts @('NODE1','NODE2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE3' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
    }

    It 'reports FixesViolation when moving VM onto an allowed host' {
        # VM1 currently on NODE3 (not allowed); moving to NODE1 (allowed) fixes it
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE3')
        $rule   = New-VmHostAffinityRule -VMs @('VM1') -Hosts @('NODE1','NODE2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE1' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }

    It 'is neutral when VM is already on allowed host and moves to another allowed host' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-VmHostAffinityRule -VMs @('VM1') -Hosts @('NODE1','NODE2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-MigrationRuleImpact — VmHostAntiAffinity' {

    It 'detects a hard violation when moving VM onto an excluded host' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-VmHostAntiAffinityRule -VMs @('VM1') -Hosts @('NODE2','NODE3') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeTrue
    }

    It 'reports FixesViolation when moving VM off an excluded host' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE2')
        $rule   = New-VmHostAntiAffinityRule -VMs @('VM1') -Hosts @('NODE2','NODE3') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE1' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeTrue
    }

    It 'is neutral when destination is not an excluded host and source was not either' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-VmHostAntiAffinityRule -VMs @('VM1') -Hosts @('NODE3') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation | Should -BeFalse
        $result.FixesViolation   | Should -BeFalse
    }
}

Describe 'Get-MigrationRuleImpact — output object structure' {

    It 'always returns an object with all 6 expected properties' {
        $snap   = New-ImpactSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @()
        $result.PSObject.Properties.Name | Should -Contain 'HasHardViolation'
        $result.PSObject.Properties.Name | Should -Contain 'HasSoftViolation'
        $result.PSObject.Properties.Name | Should -Contain 'FixesViolation'
        $result.PSObject.Properties.Name | Should -Contain 'HardReasons'
        $result.PSObject.Properties.Name | Should -Contain 'SoftReasons'
        $result.PSObject.Properties.Name | Should -Contain 'FixReasons'
    }

    It 'HardReasons is non-empty when HasHardViolation is true' {
        $snap = New-ImpactSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-VmVmAffinityRule -VMs @('VM1','VM2') -Enforced $true
        $result = Get-MigrationRuleImpact -VMName 'VM1' -DestinationNode 'NODE2' `
                                          -Snapshot $snap -RuleSet @($rule)
        $result.HasHardViolation    | Should -BeTrue
        $result.HardReasons.Count   | Should -BeGreaterThan 0
        $result.SoftReasons.Count   | Should -Be 0
    }
}
