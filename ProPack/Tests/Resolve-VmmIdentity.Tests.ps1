#Requires -Module Pester
<#
    Unit tests for Resolve-VmmIdentity / Test-HvDrsHostNameMatch.
    Get-SCVirtualMachine and Get-SCVMHost are stubbed and mocked, since the real
    VMM console module is not present on developer workstations / CI agents.
#>

BeforeAll {
    function Get-SCVirtualMachine { param($All, $VMMServer, $ErrorAction) }
    function Get-SCVMHost { param($VMMServer, $ErrorAction) }

    . "$PSScriptRoot/../Scripts/Resolve-VmmIdentity.ps1"

    $script:targetVMId = [System.Guid]::NewGuid().ToString()

    function New-VmmVm {
        param([string]$VMId = $script:targetVMId, [string]$Name = 'VM01')
        [PSCustomObject]@{ Name = $Name; VMId = $VMId }
    }
    function New-VmmHost {
        param([string]$Name = 'HOST-B')
        [PSCustomObject]@{ Name = $Name }
    }
}

Describe 'Test-HvDrsHostNameMatch' {
    It 'matches identical names' {
        Test-HvDrsHostNameMatch -CandidateName 'HOST-B' -TargetName 'HOST-B' | Should -BeTrue
    }
    It 'matches case-insensitively' {
        Test-HvDrsHostNameMatch -CandidateName 'host-b' -TargetName 'HOST-B' | Should -BeTrue
    }
    It 'matches an FQDN against a short name' {
        Test-HvDrsHostNameMatch -CandidateName 'HOST-B.contoso.com' -TargetName 'HOST-B' | Should -BeTrue
    }
    It 'matches a short name against an FQDN' {
        Test-HvDrsHostNameMatch -CandidateName 'HOST-B' -TargetName 'HOST-B.contoso.com' | Should -BeTrue
    }
    It 'does not match unrelated names' {
        Test-HvDrsHostNameMatch -CandidateName 'HOST-B' -TargetName 'HOST-C' | Should -BeFalse
    }
    It 'returns false for empty input' {
        Test-HvDrsHostNameMatch -CandidateName '' -TargetName 'HOST-B' | Should -BeFalse
    }
}

Describe 'Resolve-VmmIdentity' {

    It 'resolves both VM and host when VMId and destination node match' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-B') }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeTrue
        $result.VirtualMachine.Name | Should -Be 'VM01'
        $result.VMHost.Name | Should -Be 'HOST-B'
        $result.FailureReason | Should -BeNullOrEmpty
    }

    It 'resolves the host when VMM reports an FQDN and HVDRS reports a short name' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-B.contoso.com') }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeTrue
        $result.VMHost.Name | Should -Be 'HOST-B.contoso.com'
    }

    It 'fails soft when no VM matches the given VMId' {
        Mock Get-SCVirtualMachine { @(New-VmmVm -VMId ([System.Guid]::NewGuid().ToString())) }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-B') }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeFalse
        $result.VirtualMachine | Should -BeNullOrEmpty
        $result.FailureReason | Should -Match 'No VMM-managed virtual machine'
    }

    It 'fails soft when no host matches the destination node' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-C') }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeFalse
        $result.VMHost | Should -BeNullOrEmpty
        $result.FailureReason | Should -Match 'No VMM-managed host'
    }

    It 'fails soft when there are multiple VMM hosts and only one matches' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-A'), (New-VmmHost -Name 'HOST-B'), (New-VmmHost -Name 'HOST-C') }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeTrue
        $result.VMHost.Name | Should -Be 'HOST-B'
    }

    It 'fails soft when Get-SCVirtualMachine throws' {
        Mock Get-SCVirtualMachine { throw 'VMM server unreachable' }
        Mock Get-SCVMHost { @(New-VmmHost) }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B'

        $result.Resolved | Should -BeFalse
        $result.FailureReason | Should -Match 'Failed to query Get-SCVirtualMachine'
    }

    It 'passes -VMMServer through to both VMM cmdlets when provided' {
        Mock Get-SCVirtualMachine { @(New-VmmVm) } -ParameterFilter { $VMMServer -eq 'VMM01' }
        Mock Get-SCVMHost { @(New-VmmHost -Name 'HOST-B') } -ParameterFilter { $VMMServer -eq 'VMM01' }

        $result = Resolve-VmmIdentity -VMId $script:targetVMId -DestinationNodeName 'HOST-B' -VMMServer 'VMM01'

        $result.Resolved | Should -BeTrue
        Should -Invoke Get-SCVirtualMachine -ParameterFilter { $VMMServer -eq 'VMM01' }
        Should -Invoke Get-SCVMHost -ParameterFilter { $VMMServer -eq 'VMM01' }
    }
}
