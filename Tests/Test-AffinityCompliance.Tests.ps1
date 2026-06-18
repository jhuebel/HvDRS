#Requires -Module Pester
<#
    Unit tests for Test-AffinityCompliance.
    No FailoverClusters or Hyper-V modules are required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Functions/Private/Test-AffinityCompliance.ps1"

    function New-ComplianceSnapshot {
        param([PSCustomObject[]]$VMs)
        New-Snapshot -Nodes @(
            New-HostMetrics -Name 'NODE1'
            New-HostMetrics -Name 'NODE2'
            New-HostMetrics -Name 'NODE3'
        ) -VMs $VMs
    }

    function New-Rule {
        param(
            [string]   $Id,
            [string]   $Name,
            [string]   $Type,
            [bool]     $Enforced = $true,
            [string[]] $VMs      = @(),
            [string[]] $Hosts    = @()
        )
        [PSCustomObject]@{ RuleId=$Id; Name=$Name; Type=$Type; Enforced=$Enforced; VMs=$VMs; Hosts=$Hosts }
    }
}

Describe 'Test-AffinityCompliance — no-op cases' {

    It 'returns empty array when RuleSet is empty' {
        $snap   = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @()
        @($result).Count | Should -Be 0
    }

    It 'returns empty array when RuleSet is null' {
        $snap   = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet $null
        @($result).Count | Should -Be 0
    }

    It 'skips rules whose VMs are not in the snapshot' {
        $snap = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule = New-Rule -Id 'r1' -Name 'Gone' -Type 'VmVmAffinity' -VMs @('VM_GONE1','VM_GONE2')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }
}

Describe 'Test-AffinityCompliance — VmVmAffinity' {

    It 'reports no violation when group is co-located' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-Rule -Id 'r1' -Name 'Aff' -Type 'VmVmAffinity' -VMs @('VM1','VM2')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports one violation when group is split across two nodes' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule    = New-Rule -Id 'r1' -Name 'Aff' -Type 'VmVmAffinity' -VMs @('VM1','VM2')
        $result  = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $result[0].Type     | Should -Be 'VmVmAffinity'
        $result[0].RuleName | Should -Be 'Aff'
        $result[0].VMs      | Should -Contain 'VM1'
        $result[0].VMs      | Should -Contain 'VM2'
    }

    It 'only counts VMs present in snapshot (ignores offline members)' {
        # VM3 not in snapshot — rule is satisfied with VM1+VM2 on same node
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule   = New-Rule -Id 'r1' -Name 'Aff' -Type 'VmVmAffinity' -VMs @('VM1','VM2','VM3')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }
}

Describe 'Test-AffinityCompliance — VmVmAntiAffinity' {

    It 'reports no violation when all VMs are on separate nodes' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule   = New-Rule -Id 'r1' -Name 'Anti' -Type 'VmVmAntiAffinity' -VMs @('VM1','VM2')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports one violation per co-located pair' {
        # VM1 and VM2 share NODE1 — one conflict
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM3' -HostNode 'NODE2'
        )
        $rule    = New-Rule -Id 'r1' -Name 'Anti' -Type 'VmVmAntiAffinity' -VMs @('VM1','VM2','VM3')
        $result  = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $result[0].VMs | Should -Contain 'VM1'
        $result[0].VMs | Should -Contain 'VM2'
    }

    It 'reports two violations when two separate pairs are co-located' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM3' -HostNode 'NODE2'
            New-VmMetrics -Name 'VM4' -HostNode 'NODE2'
        )
        $rule    = New-Rule -Id 'r1' -Name 'Anti' -Type 'VmVmAntiAffinity' -VMs @('VM1','VM2','VM3','VM4')
        $result  = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 2
    }
}

Describe 'Test-AffinityCompliance — VmHostAffinity' {

    It 'reports no violation when VM is on an allowed host' {
        $snap   = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-Rule -Id 'r1' -Name 'HostAff' -Type 'VmHostAffinity' `
                           -VMs @('VM1') -Hosts @('NODE1','NODE2')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports one violation per VM that is on a non-allowed host' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE3'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE1'
        )
        $rule    = New-Rule -Id 'r1' -Name 'HostAff' -Type 'VmHostAffinity' `
                            -VMs @('VM1','VM2') -Hosts @('NODE1','NODE2')
        $result  = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count          | Should -Be 1
        $result[0].VMs         | Should -Contain 'VM1'
        $result[0].Description | Should -Match 'NODE3'
    }
}

Describe 'Test-AffinityCompliance — VmHostAntiAffinity' {

    It 'reports no violation when VM is not on any excluded host' {
        $snap   = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE1')
        $rule   = New-Rule -Id 'r1' -Name 'HostAnti' -Type 'VmHostAntiAffinity' `
                           -VMs @('VM1') -Hosts @('NODE2','NODE3')
        $result = Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule)
        @($result).Count | Should -Be 0
    }

    It 'reports a violation when VM is on an excluded host' {
        $snap   = New-ComplianceSnapshot @(New-VmMetrics -Name 'VM1' -HostNode 'NODE2')
        $rule   = New-Rule -Id 'r1' -Name 'HostAnti' -Type 'VmHostAntiAffinity' `
                           -VMs @('VM1') -Hosts @('NODE2','NODE3')
        $result = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count          | Should -Be 1
        $result[0].VMs         | Should -Contain 'VM1'
        $result[0].Description | Should -Match 'NODE2'
    }
}

Describe 'Test-AffinityCompliance — output fields' {

    It 'each violation includes RuleId, RuleName, Type, Enforced, VMs, Description' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $rule    = New-Rule -Id 'r99' -Name 'Test Rule' -Type 'VmVmAffinity' `
                            -Enforced $false -VMs @('VM1','VM2')
        $result  = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($rule))
        $result.Count | Should -Be 1
        $v = $result[0]
        $v.RuleId      | Should -Be 'r99'
        $v.RuleName    | Should -Be 'Test Rule'
        $v.Type        | Should -Be 'VmVmAffinity'
        $v.Enforced    | Should -BeFalse
        $v.VMs.Count   | Should -BeGreaterThan 0
        $v.Description | Should -Not -BeNullOrEmpty
    }

    It 'Enforced flag matches the source rule' {
        $snap = New-ComplianceSnapshot @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
            New-VmMetrics -Name 'VM2' -HostNode 'NODE2'
        )
        $hardRule = New-Rule -Id 'h1' -Name 'Hard' -Type 'VmVmAffinity' -Enforced $true  -VMs @('VM1','VM2')
        $softRule = New-Rule -Id 's1' -Name 'Soft' -Type 'VmVmAffinity' -Enforced $false -VMs @('VM1','VM2')
        $result   = @(Test-AffinityCompliance -Snapshot $snap -RuleSet @($hardRule, $softRule))
        ($result | Where-Object { $_.RuleId -eq 'h1' }).Enforced | Should -BeTrue
        ($result | Where-Object { $_.RuleId -eq 's1' }).Enforced | Should -BeFalse
    }
}
