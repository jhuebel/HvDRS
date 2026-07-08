#Requires -Module Pester
<#
    Unit tests for Resolve-VmmStorageIdentity.
    Get-SCVirtualMachine and Get-SCStorageVolume are stubbed and mocked, since the
    real VMM console module is not present on developer workstations / CI agents.
#>

BeforeAll {
    function Get-SCVirtualMachine { param($All, $VMMServer, $ErrorAction) }
    function Get-SCStorageVolume { param($VMMServer, $ErrorAction) }

    . "$PSScriptRoot/../Scripts/Resolve-VmmStorageIdentity.ps1"

    $script:targetVMId = [System.Guid]::NewGuid().ToString()

    function New-VmmVm {
        param([string]$VMId = $script:targetVMId, [string]$Name = 'VM01')
        [PSCustomObject]@{ Name = $Name; VMId = $VMId }
    }
    function New-VmmVolume {
        param([string]$Name = 'Volume2', [string]$Label = $null)
        [PSCustomObject]@{ Name = $Name; Label = $Label }
    }
}

Describe 'Resolve-VmmStorageIdentity' {

    It 'resolves both VM and storage volume when VMId and destination CSV name match' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCStorageVolume { @(New-VmmVolume -Name 'Volume2') }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeTrue
        $result.VirtualMachine.Name | Should -Be 'VM01'
        $result.StorageVolume.Name | Should -Be 'Volume2'
        $result.FailureReason | Should -BeNullOrEmpty
    }

    It 'matches on Label when Name does not match' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCStorageVolume { @(New-VmmVolume -Name 'VMM-Internal-Name' -Label 'Volume2') }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeTrue
        $result.StorageVolume.Label | Should -Be 'Volume2'
    }

    It 'fails soft when no VM matches the given VMId' {
        Mock Get-SCVirtualMachine { @(New-VmmVm -VMId ([System.Guid]::NewGuid().ToString())) }
        Mock Get-SCStorageVolume { @(New-VmmVolume) }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeFalse
        $result.VirtualMachine | Should -BeNullOrEmpty
        $result.FailureReason | Should -Match 'No VMM-managed virtual machine'
    }

    It 'fails soft when no storage volume matches the destination CSV name' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCStorageVolume { @(New-VmmVolume -Name 'Volume9') }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeFalse
        $result.StorageVolume | Should -BeNullOrEmpty
        $result.FailureReason | Should -Match 'No VMM-managed storage volume'
    }

    It 'fails soft when Get-SCVirtualMachine throws' {
        Mock Get-SCVirtualMachine { throw 'VMM server unreachable' }
        Mock Get-SCStorageVolume { @(New-VmmVolume) }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeFalse
        $result.FailureReason | Should -Match 'Failed to query Get-SCVirtualMachine'
    }

    It 'fails soft when Get-SCStorageVolume throws' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCStorageVolume { throw 'VMM server unreachable' }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2'

        $result.Resolved | Should -BeFalse
        $result.FailureReason | Should -Match 'Failed to query Get-SCStorageVolume'
    }

    It 'passes -VMMServer through to both VMM cmdlets when provided' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) } -ParameterFilter { $VMMServer -eq 'VMM01' }
        Mock Get-SCStorageVolume { @(New-VmmVolume) } -ParameterFilter { $VMMServer -eq 'VMM01' }

        $result = Resolve-VmmStorageIdentity -VMId $script:targetVMId -DestinationCsvName 'Volume2' -VMMServer 'VMM01'

        $result.Resolved | Should -BeTrue
        Should -Invoke Get-SCVirtualMachine -ParameterFilter { $VMMServer -eq 'VMM01' }
        Should -Invoke Get-SCStorageVolume -ParameterFilter { $VMMServer -eq 'VMM01' }
    }
}
