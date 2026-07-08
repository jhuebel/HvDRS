BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"

    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-AffinityRuleSet { param($Path, $ClusterName) ,@() }
    function Get-ClusterSnapshot { param($ClusterName, $SampleCount, $SampleIntervalSeconds) }

    . "$PSScriptRoot\..\Functions\Private\Measure-VmHappiness.ps1"
    . "$PSScriptRoot\..\Functions\Private\Get-MigrationRuleImpact.ps1"
    . "$PSScriptRoot\..\Functions\Public\Get-HvDRSCapacityForecast.ps1"
}

Describe 'Get-HvDRSCapacityForecast -RemoveNode' {

    BeforeEach {
        function Find-EvacuationDestination {
            param($VM, $Snapshot, $ExcludeNode, $RuleSet, $CpuWeight, $MemoryWeight,
                  $MaxDestinationNetworkUtil, $DestinationMemoryReserveMB,
                  $SoftRuleViolationPenalty, $RuleComplianceBonus, $ClusterName)
        }
    }

    It 'throws when the target node does not exist in the snapshot' {
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @() }

        { Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -RemoveNode 'NOSUCHNODE' } | Should -Throw
    }

    It 'reports Feasible = $true when there are no VMs on the node' {
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @() }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -RemoveNode 'NODE1'

        $result.Feasible | Should -BeTrue
        $result.VMPlacements.Count | Should -Be 0
    }

    It 'reports Feasible = $true when every VM finds a destination' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @($vm1) }
        Mock Find-EvacuationDestination { [PSCustomObject]@{ VMName = 'VM1'; DestinationNode = 'NODE2'; ProjectedScore = 90.0 } }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -RemoveNode 'NODE1'

        $result.Feasible | Should -BeTrue
        $result.VMPlacements[0].Placed | Should -BeTrue
        $result.VMPlacements[0].ProjectedNode | Should -Be 'NODE2'
    }

    It 'reports Feasible = $false when a VM has no valid destination' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1'
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @($vm1) }
        Mock Find-EvacuationDestination { $null }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -RemoveNode 'NODE1'

        $result.Feasible | Should -BeFalse
        $result.VMPlacements[0].Placed | Should -BeFalse
        $result.VMPlacements[0].ProjectedNode | Should -BeNullOrEmpty
    }

    It 'excludes the removed node from the NodeImpact report' {
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1'), (New-HostMetrics -Name 'NODE2') -VMs @() }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -RemoveNode 'NODE1'

        $result.NodeImpact.NodeName | Should -Not -Contain 'NODE1'
        $result.NodeImpact.NodeName | Should -Contain 'NODE2'
    }
}

Describe 'Get-HvDRSCapacityForecast -AddNode' {

    It 'throws when the hypothetical node name already exists' {
        Mock Get-ClusterSnapshot { New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @() }

        { Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE1' } | Should -Throw
    }

    It 'absorbs an unhappy VM onto the new idle node' {
        # NODE1 fully loaded; VM1 CPU-starved -> unhappy
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 150.0
        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -TotalMemMB 131072 -AvailMemMB 30000 -LPs 32 -NetUtil 10.0) -VMs @($vm1)
        }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE9' -AddNodeCpuCores 32 -AddNodeMemoryMB 131072

        $result.AbsorbedRecommendations.Count | Should -Be 1
        $result.AbsorbedRecommendations[0].VMName | Should -Be 'VM1'
        $result.AbsorbedRecommendations[0].ProjectedScore | Should -BeGreaterThan $result.AbsorbedRecommendations[0].CurrentScore
    }

    It 'does not absorb VMs when all are already happy' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 10.0 -DynMem $true -Pressure 100.0
        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 20.0) -VMs @($vm1)
        }

        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE9'

        $result.AbsorbedRecommendations.Count | Should -Be 0
    }

    It 'warns when the hypothetical node''s network utilization is at or above the gate' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 100.0 -Pressure 150.0
        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -AvailMemMB 30000) -VMs @($vm1)
        }

        $warnings = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE9' -AddNodeNetworkUtil 80.0 3>&1 6>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        @($warnings).Count | Should -BeGreaterThan 0
        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE9' -AddNodeNetworkUtil 80.0 -WarningAction SilentlyContinue
        $result.AbsorbedRecommendations.Count | Should -Be 0
    }

    It 'only absorbs as many VMs as the synthetic node has memory headroom for' {
        $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 100.0 -MemAssignMB 60000 -Pressure 150.0
        $vm2 = New-VmMetrics -Name 'VM2' -HostNode 'NODE1' -CpuUtil 100.0 -MemAssignMB 60000 -Pressure 150.0
        Mock Get-ClusterSnapshot {
            New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -AvailMemMB 5000) -VMs @($vm1, $vm2)
        }

        # Synthetic node only has room for one 60000 MB VM after the 512 MB reserve
        $result = Get-HvDRSCapacityForecast -ClusterName 'TEST-CLUSTER' -AddNode 'NODE9' -AddNodeMemoryMB 65000

        $result.AbsorbedRecommendations.Count | Should -Be 1
    }
}
