#Requires -Module Pester
<#
    Unit tests for the public group CRUD functions:
        Add-HvDRSGroup
        Get-HvDRSGroup
        Remove-HvDRSGroup
        Set-HvDRSGroup

    All tests use a per-test temporary file so they never touch the real group
    store at $env:ProgramData\HvDRS\groups.json.
#>

Describe 'Groups' {

BeforeAll {
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSDataRoot.ps1"
    . "$PSScriptRoot/../Functions/Private/Get-HvDRSGroupSet.ps1"
    . "$PSScriptRoot/../Functions/Public/Groups.ps1"
}

BeforeEach {
    $testGroupsPath = [System.IO.Path]::GetTempFileName() + '.json'
}

AfterEach {
    if (Test-Path -LiteralPath $testGroupsPath) {
        Remove-Item -LiteralPath $testGroupsPath -Force
    }
}

Describe 'Add-HvDRSGroup' {

    It 'creates a Vm group and persists it' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'SQL VMs' -Type Vm -Members @('SQL1','SQL2') -GroupsPath $testGroupsPath

        $group = Get-HvDRSGroup -ClusterName 'CLUSTER1' -GroupsPath $testGroupsPath
        $group.Count       | Should -Be 1
        $group[0].Name     | Should -Be 'SQL VMs'
        $group[0].Type     | Should -Be 'Vm'
        $group[0].Members  | Should -Be @('SQL1','SQL2')
        $group[0].ClusterName | Should -Be 'CLUSTER1'
    }

    It 'assigns a unique GUID as GroupId' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'G1' -Type Host -Members @('N1') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'CLUSTER1' -GroupsPath $testGroupsPath

        { [System.Guid]::Parse($group[0].GroupId) } | Should -Not -Throw
    }

    It 'warns and does not duplicate when a group with the same name exists in the same cluster' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'G1' -Type Vm -Members @('VM2') -GroupsPath $testGroupsPath -WarningAction SilentlyContinue

        $group = Get-HvDRSGroup -ClusterName 'CLUSTER1' -GroupsPath $testGroupsPath
        $group.Count | Should -Be 1
    }

    It 'allows the same group name across different clusters' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        Add-HvDRSGroup -ClusterName 'DEV'  -Name 'G1' -Type Vm -Members @('VM2') -GroupsPath $testGroupsPath

        $all = Get-HvDRSGroup -GroupsPath $testGroupsPath
        $all.Count | Should -Be 2
    }

    It '-WhatIf does not create the file' {
        Add-HvDRSGroup -ClusterName 'CLUSTER1' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath -WhatIf
        Test-Path -LiteralPath $testGroupsPath | Should -BeFalse
    }
}

Describe 'Get-HvDRSGroup' {

    BeforeEach {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'SQL VMs' -Type Vm   -Members @('SQL1') -GroupsPath $testGroupsPath
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'Rack A'  -Type Host -Members @('N1')   -GroupsPath $testGroupsPath
        Add-HvDRSGroup -ClusterName 'DEV'  -Name 'Dev VMs' -Type Vm   -Members @('DEV1') -GroupsPath $testGroupsPath
    }

    It 'returns all groups across all clusters when -ClusterName is omitted' {
        $all = Get-HvDRSGroup -GroupsPath $testGroupsPath
        $all.Count | Should -Be 3
    }

    It 'returns only the specified cluster''s groups' {
        $prod = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath
        $prod.Count | Should -Be 2
    }

    It 'filters by Type' {
        $hostGroups = Get-HvDRSGroup -ClusterName 'PROD' -Type Host -GroupsPath $testGroupsPath
        $hostGroups.Count | Should -Be 1
        $hostGroups[0].Name | Should -Be 'Rack A'
    }

    It 'filters by wildcard Name' {
        $matched = Get-HvDRSGroup -Name 'SQL*' -GroupsPath $testGroupsPath
        $matched.Count | Should -Be 1
    }

    It 'returns an empty array (not $null) when nothing matches' {
        $matched = Get-HvDRSGroup -Name 'NoSuchGroup' -GroupsPath $testGroupsPath
        ($null -eq $matched) | Should -BeFalse
        @($matched).Count | Should -Be 0
    }
}

Describe 'Remove-HvDRSGroup' {

    It 'removes a group by name' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        Remove-HvDRSGroup -Name 'G1' -ClusterName 'PROD' -GroupsPath $testGroupsPath

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath).Count | Should -Be 0
    }

    It 'removes a group by GroupId' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath
        Remove-HvDRSGroup -GroupId $group[0].GroupId -GroupsPath $testGroupsPath

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath).Count | Should -Be 0
    }

    It 'does not affect a same-named group in a different cluster' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        Add-HvDRSGroup -ClusterName 'DEV'  -Name 'G1' -Type Vm -Members @('VM2') -GroupsPath $testGroupsPath

        Remove-HvDRSGroup -Name 'G1' -ClusterName 'PROD' -GroupsPath $testGroupsPath

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath).Count | Should -Be 0
        (Get-HvDRSGroup -ClusterName 'DEV'  -GroupsPath $testGroupsPath).Count | Should -Be 1
    }

    It 'warns and does nothing for a non-existent name' {
        Remove-HvDRSGroup -Name 'NoSuch' -GroupsPath $testGroupsPath -WarningAction SilentlyContinue
    }

    It '-WhatIf does not remove the group' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        Remove-HvDRSGroup -Name 'G1' -ClusterName 'PROD' -GroupsPath $testGroupsPath -WhatIf

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath).Count | Should -Be 1
    }
}

Describe 'Set-HvDRSGroup' {

    It 'renames the group' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath

        Set-HvDRSGroup -GroupId $group[0].GroupId -NewName 'G1-Renamed' -GroupsPath $testGroupsPath

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath)[0].Name | Should -Be 'G1-Renamed'
    }

    It 'adds members without duplicating' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath

        Set-HvDRSGroup -GroupId $group[0].GroupId -AddMembers @('VM1','VM2') -GroupsPath $testGroupsPath

        $updated = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath
        @($updated[0].Members) | Sort-Object | Should -Be @('VM1','VM2')
    }

    It 'removes members' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1','VM2') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath

        Set-HvDRSGroup -GroupId $group[0].GroupId -RemoveMembers @('VM1') -GroupsPath $testGroupsPath

        $updated = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath
        @($updated[0].Members) | Should -Be @('VM2')
    }

    It 'warns and does nothing for an unknown GroupId' {
        Set-HvDRSGroup -GroupId ([System.Guid]::NewGuid().ToString()) -NewName 'X' -GroupsPath $testGroupsPath -WarningAction SilentlyContinue
    }

    It '-WhatIf does not persist changes' {
        Add-HvDRSGroup -ClusterName 'PROD' -Name 'G1' -Type Vm -Members @('VM1') -GroupsPath $testGroupsPath
        $group = Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath

        Set-HvDRSGroup -GroupId $group[0].GroupId -NewName 'ShouldNotStick' -GroupsPath $testGroupsPath -WhatIf

        (Get-HvDRSGroup -ClusterName 'PROD' -GroupsPath $testGroupsPath)[0].Name | Should -Be 'G1'
    }
}

}
