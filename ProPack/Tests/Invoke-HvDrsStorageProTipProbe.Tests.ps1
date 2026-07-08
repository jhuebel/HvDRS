#Requires -Module Pester
<#
    Unit tests for Invoke-HvDrsStorageProTipProbe.
    All collaborators (Invoke-HvStorageDRS, ConvertTo-HvDrsStorageProTip,
    Resolve-VmmStorageIdentity, New-HvDrsScriptApi) are stubbed and mocked — no
    real cluster, VMM, or SCOM agent is required.
#>

BeforeAll {
    . "$PSScriptRoot/../../Tests/Helpers/New-TestObjects.ps1"

    function Invoke-HvStorageDRS { param($ClusterName, [switch]$RecommendOnly, [switch]$PassThru, $AggressionLevel) }
    function Resolve-VmmStorageIdentity { param($VMId, $DestinationCsvName, $VMMServer) }
    function New-HvDrsScriptApi { }

    # ConvertTo-HvDrsStorageProTip is a pure function with no external dependencies
    # — dot-source the real implementation rather than stubbing it, so the objects
    # flowing through this probe actually have Title/Description/Urgency/TriggerType
    # set, matching production behavior.
    . "$PSScriptRoot/../Scripts/ConvertTo-HvDrsStorageProTip.ps1"
    . "$PSScriptRoot/../Scripts/Invoke-HvDrsStorageProTipProbe.ps1"

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

    function New-ResolvedStorageIdentity {
        param([string]$VmmVmId = 'vmm-vm-1', [string]$VmmVolumeId = 'vmm-volume-1')
        [PSCustomObject]@{
            Resolved       = $true
            VirtualMachine = [PSCustomObject]@{ ID = $VmmVmId }
            StorageVolume  = [PSCustomObject]@{ ID = $VmmVolumeId }
            FailureReason  = $null
        }
    }

    function New-UnresolvedStorageIdentity {
        param([string]$Reason = 'not found')
        [PSCustomObject]@{
            Resolved       = $false
            VirtualMachine = $null
            StorageVolume  = $null
            FailureReason  = $Reason
        }
    }
}

Describe 'Invoke-HvDrsStorageProTipProbe' {

    It 'emits a single property bag with RecommendationCount 0 when there are no recommendations' {
        Mock Invoke-HvStorageDRS { @() }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER')

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 0
    }

    It 'emits one property bag per resolved recommendation, with VMM identity fields populated' {
        Mock Invoke-HvStorageDRS { @(New-StorageMigrationRecommendation -VMName 'VM01' -DestinationCSVName 'Volume2') }
        Mock Resolve-VmmStorageIdentity { New-ResolvedStorageIdentity }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER')

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 1
        $bags[0].VMName | Should -Be 'VM01'
        $bags[0].VMMVirtualMachineId | Should -Be 'vmm-vm-1'
        $bags[0].VMMStorageVolumeId | Should -Be 'vmm-volume-1'
    }

    It 'skips a recommendation whose VMM identity cannot be resolved, without affecting others' {
        Mock Invoke-HvStorageDRS {
            @(
                New-StorageMigrationRecommendation -VMName 'VM-UNRESOLVABLE'
                New-StorageMigrationRecommendation -VMName 'VM-OK'
            )
        }
        $script:callIndex = -1
        Mock Resolve-VmmStorageIdentity {
            $script:callIndex++
            if ($script:callIndex -eq 0) { New-UnresolvedStorageIdentity } else { New-ResolvedStorageIdentity }
        }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER' 3>$null)

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 1
        $bags[0].VMName | Should -Be 'VM-OK'
    }

    It 'emits a single zero-count bag when every recommendation fails identity resolution' {
        Mock Invoke-HvStorageDRS { @(New-StorageMigrationRecommendation -VMName 'VM-UNRESOLVABLE') }
        Mock Resolve-VmmStorageIdentity { New-UnresolvedStorageIdentity }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        $bags = @(Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER' 3>$null)

        $bags.Count | Should -Be 1
        $bags[0].RecommendationCount | Should -Be 0
    }

    It 'passes ClusterName, RecommendOnly, PassThru, and AggressionLevel through to Invoke-HvStorageDRS' {
        Mock Invoke-HvStorageDRS { @() } -ParameterFilter {
            $ClusterName -eq 'TEST-CLUSTER' -and $RecommendOnly -and $PassThru -and $AggressionLevel -eq 4
        }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER' -AggressionLevel 4 | Out-Null

        Should -Invoke Invoke-HvStorageDRS -ParameterFilter {
            $ClusterName -eq 'TEST-CLUSTER' -and $RecommendOnly -and $PassThru -and $AggressionLevel -eq 4
        }
    }

    It 'passes VMMServer through to Resolve-VmmStorageIdentity' {
        Mock Invoke-HvStorageDRS { @(New-StorageMigrationRecommendation -VMName 'VM01') }
        Mock Resolve-VmmStorageIdentity { New-ResolvedStorageIdentity } -ParameterFilter { $VMMServer -eq 'VMM01' }
        Mock New-HvDrsScriptApi { New-FakeScriptApi }

        Invoke-HvDrsStorageProTipProbe -ClusterName 'TEST-CLUSTER' -VMMServer 'VMM01' | Out-Null

        Should -Invoke Resolve-VmmStorageIdentity -ParameterFilter { $VMMServer -eq 'VMM01' }
    }
}
