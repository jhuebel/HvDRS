BeforeAll {
    if (-not (Get-Command Get-ClusterOwnerNode -ErrorAction SilentlyContinue)) {
        function Get-ClusterOwnerNode { }
    }

    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"
    . "$PSScriptRoot\..\Functions\Private\Measure-VmHappiness.ps1"
    . "$PSScriptRoot\..\Functions\Private\Get-MigrationRuleImpact.ps1"
    . "$PSScriptRoot\..\Functions\Private\Find-EvacuationDestination.ps1"
}

Describe 'Find-EvacuationDestination' {

    BeforeEach {
        # NODE1 is being drained; NODE2/NODE3 are candidates
        $script:n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 50.0 -TotalMemMB 131072 -AvailMemMB 30000 -LPs 32 -NetUtil 10.0
        $script:n2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 -TotalMemMB 131072 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
        $script:n3 = New-HostMetrics -Name 'NODE3' -CpuUtil 40.0 -TotalMemMB 131072 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
        $script:vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 30.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 100.0
        $script:snapshot = New-Snapshot -Nodes @($script:n1, $script:n2, $script:n3) -VMs @($script:vm1)

        Mock Get-ClusterOwnerNode { [PSCustomObject]@{ OwnerNodes = @([PSCustomObject]@{ Name = 'NODE1' }, [PSCustomObject]@{ Name = 'NODE2' }, [PSCustomObject]@{ Name = 'NODE3' }) } }
    }

    It 'picks the only valid candidate' {
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result | Should -Not -BeNullOrEmpty
        $result.DestinationNode | Should -BeIn @('NODE2', 'NODE3')
        $result.VMName          | Should -Be 'VM1'
        $result.SourceNode      | Should -Be 'NODE1'
    }

    It 'excludes a candidate at or above MaxDestinationNetworkUtil' {
        $n2.NetworkUtilization = 75.0   # above default 70% gate
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Be 'NODE3'
    }

    It 'excludes a candidate that would fall below DestinationMemoryReserveMB' {
        $n2.AvailableMemoryMB = 8000   # 8000 - 8192 (VM) < 512 reserve
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Be 'NODE3'
    }

    It 'restricts candidates to the cluster possible-owner list' {
        Mock Get-ClusterOwnerNode { [PSCustomObject]@{ OwnerNodes = @([PSCustomObject]@{ Name = 'NODE1' }, [PSCustomObject]@{ Name = 'NODE3' }) } }

        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Be 'NODE3'
    }

    It 'treats all nodes as eligible when Get-ClusterOwnerNode throws' {
        Mock Get-ClusterOwnerNode { throw 'group not found' }

        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result | Should -Not -BeNullOrEmpty
    }

    It 'excludes a candidate that would break an enforced rule' {
        $vm2 = New-VmMetrics -Name 'VM2' -HostNode 'NODE2' -CpuUtil 10.0
        $snapshot.VMs = @($vm1, $vm2)
        $rule = [PSCustomObject]@{ RuleId='r1'; Name='AA'; Type='VmVmAntiAffinity'; Enforced=$true; VMs=@('VM1','VM2'); Hosts=@(); CSVs=@() }

        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -RuleSet @($rule) -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Be 'NODE3'
    }

    It 'returns $null and mutates nothing when no valid destination exists' {
        $n2.AvailableMemoryMB = 0
        $n3.AvailableMemoryMB = 0
        $snapshot.Nodes = @($n1, $n2, $n3)

        $originalVmHost = $vm1.HostNode
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result | Should -BeNullOrEmpty
        $vm1.HostNode | Should -Be $originalVmHost
    }

    It 'picks the destination with the highest projected happiness when multiple are valid' {
        # NODE3 more loaded than NODE2 -> NODE2 should score higher
        $n3.CpuUtilization = 95.0
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Be 'NODE2'
    }

    It 'applies the greedy state update: destination node capacity and VM.HostNode change' {
        $before = $n2.AvailableMemoryMB
        $result = Find-EvacuationDestination -VM $vm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $result.DestinationNode | Should -Not -BeNullOrEmpty
        $destNode = $snapshot.Nodes | Where-Object { $_.NodeName -eq $result.DestinationNode }
        $destNode.AvailableMemoryMB | Should -BeLessThan $before
        $vm1.HostNode | Should -Be $result.DestinationNode
    }

    It 'does not double-book a destination across two sequential calls for two VMs' {
        # NODE2 only has room for one of the two 50000 MB VMs (after 512 reserve)
        $n2.AvailableMemoryMB = 60000
        $n3.AvailableMemoryMB = 60000
        $bigVm1 = New-VmMetrics -Name 'BIG1' -HostNode 'NODE1' -CpuUtil 10.0 -MemAssignMB 50000
        $bigVm2 = New-VmMetrics -Name 'BIG2' -HostNode 'NODE1' -CpuUtil 10.0 -MemAssignMB 50000
        $snapshot.VMs = @($bigVm1, $bigVm2)

        $r1 = Find-EvacuationDestination -VM $bigVm1 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'
        $r2 = Find-EvacuationDestination -VM $bigVm2 -Snapshot $snapshot -ExcludeNode 'NODE1' -ClusterName 'TEST-CLUSTER'

        $r1.DestinationNode | Should -Not -BeNullOrEmpty
        $r2.DestinationNode | Should -Not -BeNullOrEmpty
        $r1.DestinationNode | Should -Not -Be $r2.DestinationNode
    }
}
