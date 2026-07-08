BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"
    . "$PSScriptRoot\..\Functions\Private\Merge-HvDRSTrendSnapshot.ps1"
}

Describe 'Merge-HvDRSTrendSnapshot' {

    BeforeEach {
        $script:historyPath = 'TestDrive:\history.json'
    }

    It 'bootstraps a single-entry window when the history file does not exist' {
        $snapshot = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 80.0) -VMs @()

        $result = Merge-HvDRSTrendSnapshot -Snapshot $snapshot -HistoryPath $historyPath -WindowSize 3

        $result.Nodes[0].CpuUtilization | Should -Be 80.0
        Test-Path -LiteralPath $historyPath | Should -BeTrue
    }

    It 'falls back to a fresh window when the history file is corrupt' {
        Set-Content -LiteralPath $historyPath -Value '{ not valid json'
        $snapshot = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 42.0) -VMs @()

        $result = Merge-HvDRSTrendSnapshot -Snapshot $snapshot -HistoryPath $historyPath -WindowSize 3 -WarningAction SilentlyContinue

        $result.Nodes[0].CpuUtilization | Should -Be 42.0
    }

    It 'averages node CPU/network utilization across multiple passes' {
        $s1 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 60.0 -NetUtil 10.0) -VMs @()
        $s2 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 80.0 -NetUtil 20.0) -VMs @()
        $s3 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -NetUtil 30.0) -VMs @()

        Merge-HvDRSTrendSnapshot -Snapshot $s1 -HistoryPath $historyPath -WindowSize 3 | Out-Null
        Merge-HvDRSTrendSnapshot -Snapshot $s2 -HistoryPath $historyPath -WindowSize 3 | Out-Null
        $result = Merge-HvDRSTrendSnapshot -Snapshot $s3 -HistoryPath $historyPath -WindowSize 3

        $result.Nodes[0].CpuUtilization     | Should -Be 80.0   # (60+80+100)/3
        $result.Nodes[0].NetworkUtilization | Should -Be 20.0   # (10+20+30)/3
    }

    It 'averages VM CPU utilization and memory pressure across multiple passes' {
        $s1 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(New-VmMetrics -Name 'VM1' -CpuUtil 10.0 -Pressure 100.0)
        $s2 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(New-VmMetrics -Name 'VM1' -CpuUtil 30.0 -Pressure 140.0)

        Merge-HvDRSTrendSnapshot -Snapshot $s1 -HistoryPath $historyPath -WindowSize 2 | Out-Null
        $result = Merge-HvDRSTrendSnapshot -Snapshot $s2 -HistoryPath $historyPath -WindowSize 2

        $result.VMs[0].CpuUtilization | Should -Be 20.0   # (10+30)/2
        $result.VMs[0].MemoryPressure | Should -Be 120.0  # (100+140)/2
    }

    It 'trims history to WindowSize, dropping the oldest entry' {
        $s1 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 0.0) -VMs @()
        $s2 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 50.0) -VMs @()
        $s3 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -CpuUtil 100.0) -VMs @()

        Merge-HvDRSTrendSnapshot -Snapshot $s1 -HistoryPath $historyPath -WindowSize 2 | Out-Null
        Merge-HvDRSTrendSnapshot -Snapshot $s2 -HistoryPath $historyPath -WindowSize 2 | Out-Null
        $result = Merge-HvDRSTrendSnapshot -Snapshot $s3 -HistoryPath $historyPath -WindowSize 2

        # s1 (CPU=0) should have been dropped; only s2 (50) and s3 (100) remain
        $result.Nodes[0].CpuUtilization | Should -Be 75.0

        $stored = Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json
        $stored.Entries.Count | Should -Be 2
    }

    It 'averages a VM only over the entries in which it appears' {
        $s1 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(New-VmMetrics -Name 'VM1' -CpuUtil 10.0)
        $s2 = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(
            (New-VmMetrics -Name 'VM1' -CpuUtil 30.0),
            (New-VmMetrics -Name 'VM2' -CpuUtil 90.0)
        )

        Merge-HvDRSTrendSnapshot -Snapshot $s1 -HistoryPath $historyPath -WindowSize 3 | Out-Null
        $result = Merge-HvDRSTrendSnapshot -Snapshot $s2 -HistoryPath $historyPath -WindowSize 3

        ($result.VMs | Where-Object VMName -eq 'VM1').CpuUtilization | Should -Be 20.0  # (10+30)/2
        ($result.VMs | Where-Object VMName -eq 'VM2').CpuUtilization | Should -Be 90.0  # only appears once
    }

    It 'passes through capacity fields unchanged rather than averaging them' {
        $snapshot = New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1' -TotalMemMB 65536 -AvailMemMB 32768 -LPs 16) -VMs @()

        $result = Merge-HvDRSTrendSnapshot -Snapshot $snapshot -HistoryPath $historyPath -WindowSize 3

        $result.Nodes[0].TotalMemoryMB         | Should -Be 65536
        $result.Nodes[0].AvailableMemoryMB     | Should -Be 32768
        $result.Nodes[0].LogicalProcessorCount | Should -Be 16
    }

    It 'preserves ClusterName and non-smoothed VM identity fields' {
        $snapshot = New-Snapshot -ClusterName 'MY-CLUSTER' -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @(
            New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -Procs 8 -MemAssignMB 16384
        )

        $result = Merge-HvDRSTrendSnapshot -Snapshot $snapshot -HistoryPath $historyPath -WindowSize 3

        $result.ClusterName          | Should -Be 'MY-CLUSTER'
        $result.VMs[0].HostNode      | Should -Be 'NODE1'
        $result.VMs[0].ProcessorCount | Should -Be 8
        $result.VMs[0].MemoryAssignedMB | Should -Be 16384
    }
}
