BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"

    # Stub every cluster/Hyper-V cmdlet these functions call so tests run without
    # FailoverClusters/Hyper-V installed — mirrors the stubbing pattern used in
    # Tests/Invoke-HvDRS.Tests.ps1.
    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-AffinityRuleSet { param($Path, $ClusterName) ,@() }
    function Get-ClusterSnapshot { param($ClusterName, $SampleCount, $SampleIntervalSeconds) New-Snapshot }
    function Find-EvacuationDestination {
        param($VM, $Snapshot, $ExcludeNode, $RuleSet, $CpuWeight, $MemoryWeight,
              $MaxDestinationNetworkUtil, $DestinationMemoryReserveMB,
              $SoftRuleViolationPenalty, $RuleComplianceBonus, $ClusterName)
    }
    function Move-ClusterVirtualMachineRole { param($Cluster, $Name, $Node, $MigrationType) }
    function Suspend-ClusterNode { param($Cluster, $Name) }
    function Resume-ClusterNode { param($Cluster, $Name) }
    function Get-ClusterNode { param($Cluster) }

    . "$PSScriptRoot\..\Functions\Public\Maintenance.ps1"
}

Describe 'Enter-HvDRSNodeMaintenance' {

    It 'reports no VMs to evacuate and pauses the node when it is already empty' {
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @() }
        Mock Suspend-ClusterNode { }

        $result = Enter-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -Confirm:$false

        $result.AllPlaced  | Should -BeTrue
        $result.NodePaused | Should -BeTrue
        $result.Evacuated.Count | Should -Be 0
        Should -Invoke Suspend-ClusterNode -Times 1
    }

    It 'migrates each VM on the node to its found destination and pauses the node' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @($vm1) }
        Mock Find-EvacuationDestination { [PSCustomObject]@{ VMName = 'VM1'; DestinationNode = 'NODE2'; ProjectedScore = 90.0 } }
        Mock Move-ClusterVirtualMachineRole { }
        Mock Suspend-ClusterNode { }

        $result = Enter-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -Confirm:$false

        $result.AllPlaced  | Should -BeTrue
        $result.NodePaused | Should -BeTrue
        $result.Evacuated[0].Succeeded       | Should -BeTrue
        $result.Evacuated[0].DestinationNode | Should -Be 'NODE2'
        Should -Invoke Move-ClusterVirtualMachineRole -Times 1 -ParameterFilter { $Name -eq 'VM1' -and $Node -eq 'NODE2' }
        Should -Invoke Suspend-ClusterNode -Times 1
    }

    It 'does NOT pause the node when a VM has no valid destination' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @($vm1) }
        Mock Find-EvacuationDestination { $null }
        Mock Suspend-ClusterNode { }

        $result = Enter-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -WarningAction SilentlyContinue

        $result.AllPlaced  | Should -BeFalse
        $result.NodePaused | Should -BeFalse
        $result.Evacuated[0].Succeeded | Should -BeFalse
        Should -Invoke Suspend-ClusterNode -Times 0
    }

    It 'does NOT pause the node when a migration fails' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @($vm1) }
        Mock Find-EvacuationDestination { [PSCustomObject]@{ VMName = 'VM1'; DestinationNode = 'NODE2'; ProjectedScore = 90.0 } }
        Mock Move-ClusterVirtualMachineRole { throw 'live migration failed' }
        Mock Suspend-ClusterNode { }

        $result = Enter-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -WarningAction SilentlyContinue -Confirm:$false

        $result.AllPlaced  | Should -BeFalse
        $result.NodePaused | Should -BeFalse
        Should -Invoke Suspend-ClusterNode -Times 0
    }

    It '-WhatIf previews without migrating or pausing' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @($vm1) }
        Mock Find-EvacuationDestination { [PSCustomObject]@{ VMName = 'VM1'; DestinationNode = 'NODE2'; ProjectedScore = 90.0 } }
        Mock Move-ClusterVirtualMachineRole { }
        Mock Suspend-ClusterNode { }

        $result = Enter-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -WhatIf

        Should -Invoke Move-ClusterVirtualMachineRole -Times 0
        Should -Invoke Suspend-ClusterNode -Times 0
    }
}

Describe 'Exit-HvDRSNodeMaintenance' {

    It 'calls Resume-ClusterNode for the specified node' {
        Mock Resume-ClusterNode { }

        Exit-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1'

        Should -Invoke Resume-ClusterNode -Times 1 -ParameterFilter { $Name -eq 'NODE1' -and $Cluster -eq 'TEST-CLUSTER' }
    }

    It '-WhatIf does not call Resume-ClusterNode' {
        Mock Resume-ClusterNode { }

        Exit-HvDRSNodeMaintenance -ClusterName 'TEST-CLUSTER' -NodeName 'NODE1' -WhatIf

        Should -Invoke Resume-ClusterNode -Times 0
    }
}

Describe 'Get-HvDRSNodeMaintenanceStatus' {

    It 'reports all nodes when -NodeName is omitted' {
        Mock Get-ClusterNode {
            @(
                [PSCustomObject]@{ Name = 'NODE1'; State = 'Up' },
                [PSCustomObject]@{ Name = 'NODE2'; State = 'Paused' }
            )
        }

        $result = @(Get-HvDRSNodeMaintenanceStatus -ClusterName 'TEST-CLUSTER')

        $result.Count | Should -Be 2
        ($result | Where-Object NodeName -eq 'NODE2').Paused | Should -BeTrue
        ($result | Where-Object NodeName -eq 'NODE1').Paused | Should -BeFalse
    }

    It 'filters to a single node when -NodeName is specified' {
        Mock Get-ClusterNode {
            @(
                [PSCustomObject]@{ Name = 'NODE1'; State = 'Up' },
                [PSCustomObject]@{ Name = 'NODE2'; State = 'Paused' }
            )
        }

        $result = @(Get-HvDRSNodeMaintenanceStatus -ClusterName 'TEST-CLUSTER' -NodeName 'NODE2')

        $result.Count      | Should -Be 1
        $result[0].NodeName | Should -Be 'NODE2'
        $result[0].Paused   | Should -BeTrue
    }
}
