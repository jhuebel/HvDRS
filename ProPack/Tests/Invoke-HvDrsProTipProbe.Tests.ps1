#Requires -Module Pester
<#
    Unit tests for Invoke-HvDrsProTipProbe.
    All collaborators (Invoke-HvDRS, ConvertTo-HvDrsProTip, Resolve-VmmIdentity,
    New-HvDrsScriptApi) are stubbed and mocked — no real cluster, VMM, or SCOM
    agent is required.
#>

BeforeAll {
    . "$PSScriptRoot/../../Tests/Helpers/New-TestObjects.ps1"

    function Invoke-HvDRS { param($ClusterName, [switch]$RecommendOnly, [switch]$PassThru, $AggressionLevel) }
    function Resolve-VmmIdentity { param($VMId, $DestinationNodeName, $VMMServer) }

    # ConvertTo-HvDrsProTip is a pure function with no external dependencies (see
    # its own doc comment) — dot-source the real implementation rather than
    # stubbing it, so the objects flowing through this probe actually have
    # Title/Description/Urgency/TriggerType set, matching production behavior.
    . "$PSScriptRoot/../Scripts/ConvertTo-HvDrsProTip.ps1"
    . "$PSScriptRoot/../Scripts/Invoke-HvDrsProTipProbe.ps1"

    function New-FakeBag {
        $bag = [PSCustomObject]@{}
        $bag | Add-Member -MemberType ScriptMethod -Name AddValue -Value {
            param($name, $value)
            $this | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
        }
        return $bag
    }

    function New-FakeScriptApi {
        $api = [PSCustomObject]@{}
        $api | Add-Member -MemberType ScriptMethod -Name CreatePropertyBag -Value { New-FakeBag }
        return $api
    }

    function New-ResolvedIdentity {
        param([string]$VmmVmId = 'vmm-vm-1', [string]$VmmHostId = 'vmm-host-1')
        [PSCustomObject]@{
            Resolved       = $true
            VirtualMachine = [PSCustomObject]@{ ID = $VmmVmId }
            VMHost         = [PSCustomObject]@{ ID = $VmmHostId }
            FailureReason  = $null
        }
    }

    function New-UnresolvedIdentity {
        param([string]$Reason = 'not found')
        [PSCustomObject]@{
            Resolved       = $false
            VirtualMachine = $null
            VMHost         = $null
            FailureReason  = $Reason
        }
    }
}

Describe 'Invoke-HvDrsProTipProbe' {

    It 'emits a single property bag with RecommendationCount 0 when there are no recommendations' {
        Mock Invoke-HvDRS { @() }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER')

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 0
    }

    It 'emits one property bag per resolved recommendation, with VMM identity fields populated' {
        Mock Invoke-HvDRS { @(New-MigrationRecommendation -VMName 'VM01' -DestinationNode 'HOST-B') }
        Mock Resolve-VmmIdentity { New-ResolvedIdentity }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER')

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 1
        $bags[0].VMName | Should -Be 'VM01'
        $bags[0].VMMVirtualMachineId | Should -Be 'vmm-vm-1'
        $bags[0].VMMHostId | Should -Be 'vmm-host-1'
    }

    It 'skips a recommendation whose VMM identity cannot be resolved, without affecting others' {
        Mock Invoke-HvDRS {
            @(
                New-MigrationRecommendation -VMName 'VM-UNRESOLVABLE'
                New-MigrationRecommendation -VMName 'VM-OK'
            )
        }
        $script:callIndex = -1
        Mock Resolve-VmmIdentity {
            $script:callIndex++
            if ($script:callIndex -eq 0) { New-UnresolvedIdentity } else { New-ResolvedIdentity }
        }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER' 3>$null)

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 1
        $bags[0].VMName | Should -Be 'VM-OK'
    }

    It 'emits a single zero-count bag when every recommendation fails identity resolution' {
        Mock Invoke-HvDRS { @(New-MigrationRecommendation -VMName 'VM-UNRESOLVABLE') }
        Mock Resolve-VmmIdentity { New-UnresolvedIdentity }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER' 3>$null)

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 0
    }

    It 'passes ClusterName, RecommendOnly, PassThru, and AggressionLevel through to Invoke-HvDRS' {
        Mock Invoke-HvDRS { @() } -ParameterFilter {
            $ClusterName -eq 'TEST-CLUSTER' -and $RecommendOnly -and $PassThru -and $AggressionLevel -eq 4
        }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER' -AggressionLevel 4 | Out-Null

        Should -Invoke Invoke-HvDRS -ParameterFilter {
            $ClusterName -eq 'TEST-CLUSTER' -and $RecommendOnly -and $PassThru -and $AggressionLevel -eq 4
        }
    }

    It 'passes VMMServer through to Resolve-VmmIdentity' {
        Mock Invoke-HvDRS { @(New-MigrationRecommendation -VMName 'VM01') }
        Mock Resolve-VmmIdentity { New-ResolvedIdentity } -ParameterFilter { $VMMServer -eq 'VMM01' }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        Invoke-HvDrsProTipProbe -ClusterName 'TEST-CLUSTER' -VMMServer 'VMM01' | Out-Null

        Should -Invoke Resolve-VmmIdentity -ParameterFilter { $VMMServer -eq 'VMM01' }
    }
}
