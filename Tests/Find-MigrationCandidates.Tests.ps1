BeforeAll {
    # Stub Get-ClusterOwnerNode so Pester can mock it on machines without the
    # FailoverClusters module installed (e.g. developer workstations / CI agents).
    if (-not (Get-Command Get-ClusterOwnerNode -ErrorAction SilentlyContinue)) {
        function Get-ClusterOwnerNode { }
    }

    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"
    . "$PSScriptRoot\..\Functions\Private\Measure-VmHappiness.ps1"
    . "$PSScriptRoot\..\Functions\Private\Find-MigrationCandidates.ps1"
}

Describe 'Find-MigrationCandidates' {

    # ── Shared scenario: one badly unhappy VM ──────────────────────────────────
    # NODE1 CPU=100%, VM1: cpu=100%, pressure=130  →  score=20.0  (< level-3 threshold 50)
    # NODE2 CPU=20%,  AvailMem=60000              →  projected=100.0 improvement=80.0

    BeforeAll {
        # NODE1: fully loaded (source)
        $script:n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 `
                                     -TotalMemMB 131072 -AvailMemMB 30000 `
                                     -LPs 32 -NetUtil 10.0
        # NODE2: lightly loaded (candidate destination)
        $script:n2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                     -TotalMemMB 131072 -AvailMemMB 60000 `
                                     -LPs 32 -NetUtil 5.0
        # VM1: CPU-starved and memory-pressured on NODE1
        # score: cpuHappy=0, memHappy=40 (pressure=130)  →  (0+40)/2 = 20.0
        $script:vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' `
                                    -CpuUtil 100.0 -Procs 4 `
                                    -MemAssignMB 8192 -DynMem $true -Pressure 130.0

        $script:baseSnapshot = New-Snapshot -Nodes @($script:n1, $script:n2) `
                                            -VMs   @($script:vm1)
    }

    # ── Basic triggering ───────────────────────────────────────────────────────

    Describe 'Basic migration triggering' {

        It 'recommends a migration when a VM is below the happiness threshold' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }   # fallback: all nodes allowed

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }

        It 'returns an empty list when all VMs are happy' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $happyVm       = New-VmMetrics -Name 'VM-HAPPY' -HostNode 'NODE1' `
                                           -CpuUtil 20.0 -DynMem $true -Pressure 90.0
            $happySnapshot = New-Snapshot -Nodes @($script:n1, $script:n2) -VMs @($happyVm)

            $result = Find-MigrationCandidates -Snapshot $happySnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }
    }

    # ── Network-Aware filtering ────────────────────────────────────────────────

    Describe 'Network-Aware destination filtering' {

        It 'excludes a destination node whose NIC utilization is at or above the gate' {
            # NODE2 net=80% > default gate of 70%  →  no eligible destination
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $saturatedN2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                           -TotalMemMB 131072 -AvailMemMB 60000 `
                                           -LPs 32 -NetUtil 80.0
            $snap = New-Snapshot -Nodes @($script:n1, $saturatedN2) -VMs @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }

        It 'includes a destination node whose NIC utilization is below the gate' {
            # NODE2 net=69% < 70% gate  →  eligible
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $okN2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                    -TotalMemMB 131072 -AvailMemMB 60000 `
                                    -LPs 32 -NetUtil 69.0
            $snap = New-Snapshot -Nodes @($script:n1, $okN2) -VMs @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }

        It 'respects a custom -MaxDestinationNetworkUtil gate' {
            # Default gate is 70%; with gate=50%, NODE2 net=60% should be excluded
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $midN2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                     -TotalMemMB 131072 -AvailMemMB 60000 `
                                     -LPs 32 -NetUtil 60.0
            $snap = New-Snapshot -Nodes @($script:n1, $midN2) -VMs @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                               -MaxDestinationNetworkUtil 50.0 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }
    }

    # ── Memory constraints ─────────────────────────────────────────────────────

    Describe 'Memory constraints' {

        It 'excludes a destination that would leave less free memory than the reserve' {
            # VM needs 8192 MB; NODE2 has 8700 MB free; reserve=512; 8700-8192=508 < 512  →  excluded
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $tightN2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                       -TotalMemMB 131072 -AvailMemMB 8700 `
                                       -LPs 32 -NetUtil 5.0
            $snap = New-Snapshot -Nodes @($script:n1, $tightN2) -VMs @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }

        It 'includes a destination whose post-migration free memory meets the reserve' {
            # VM needs 8192 MB; NODE2 has 9000 MB free; 9000-8192=808 ≥ 512  →  eligible
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $okN2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                    -TotalMemMB 131072 -AvailMemMB 9000 `
                                    -LPs 32 -NetUtil 5.0
            $snap = New-Snapshot -Nodes @($script:n1, $okN2) -VMs @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }
    }

    # ── Cluster ownership constraints ──────────────────────────────────────────

    Describe 'Cluster ownership constraints' {

        It 'only migrates to a node listed as a possible owner' {
            # NODE2 is NOT a possible owner; NODE3 IS  →  migration must go to NODE3
            $n3 = New-HostMetrics -Name 'NODE3' -CpuUtil 25.0 `
                                  -TotalMemMB 131072 -AvailMemMB 60000 `
                                  -LPs 32 -NetUtil 5.0
            $snap = New-Snapshot -Nodes @($script:n1, $script:n2, $n3) -VMs @($script:vm1)

            Mock Get-ClusterOwnerNode {
                [PSCustomObject]@{
                    OwnerNodes = @(
                        [PSCustomObject]@{ Name = 'NODE1' },
                        [PSCustomObject]@{ Name = 'NODE3' }
                    )
                }
            }

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count            | Should -Be 1
            $result[0].DestinationNode | Should -Be 'NODE3'
        }

        It 'falls back to all nodes when Get-ClusterOwnerNode throws' {
            # With no ownership constraint, NODE2 is eligible  →  migration recommended
            Mock Get-ClusterOwnerNode { throw 'cluster group not found' }

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }
    }

    # ── Aggression levels ──────────────────────────────────────────────────────
    # VM score = 65.0:
    #   NODE1 CPU=85%, VM cpu=60%, pressure=120
    #   cpuStress=(85-70)/30=0.5  →  cpuHappy=100-0.5*60=70
    #   memHappy=100-(120-100)*2=60  →  score=(70+60)/2=65.0

    Describe 'Aggression levels' {

        BeforeAll {
            $script:nMedLoad   = New-HostMetrics -Name 'NODE1' -CpuUtil 85.0 `
                                                  -TotalMemMB 131072 -AvailMemMB 40000 `
                                                  -LPs 32 -NetUtil 10.0
            $script:nLightLoad = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                                  -TotalMemMB 131072 -AvailMemMB 60000 `
                                                  -LPs 32 -NetUtil 5.0
            # score = 65.0
            $script:vmMid = New-VmMetrics -Name 'VM-MID' -HostNode 'NODE1' `
                                          -CpuUtil 60.0 -Procs 4 `
                                          -MemAssignMB 8192 -DynMem $true -Pressure 120.0
            $script:snapMid = New-Snapshot -Nodes @($script:nMedLoad, $script:nLightLoad) `
                                           -VMs   @($script:vmMid)
        }

        It 'does not migrate at level 4 when VM score (65) is above that level''s threshold (60)' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $result = Find-MigrationCandidates -Snapshot $script:snapMid `
                                               -AggressionLevel 4 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }

        It 'migrates at level 5 when VM score (65) is below that level''s threshold (70)' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $result = Find-MigrationCandidates -Snapshot $script:snapMid `
                                               -AggressionLevel 5 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }

        It 'does not migrate when improvement is below the level minimum' {
            # NODE1 CPU=100%, NODE2 CPU=80% AvailMem=10000 (tight: no DM normalization)
            # VM1: cpu=100%, pressure=130  →  score=20.0  (<30, level-1 threshold)
            # Projected on NODE2: simCPU=92.5, pressure stays 130
            #   cpuHappy=100-(92.5-70)/30*100=25.0, memHappy=40  →  projected=32.5
            #   improvement=12.5 < 40 (level-1 minimum)  →  no migration
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1Full  = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 `
                                       -TotalMemMB 131072 -AvailMemMB 30000 `
                                       -LPs 32 -NetUtil 10.0
            $n2Busy  = New-HostMetrics -Name 'NODE2' -CpuUtil 80.0 `
                                       -TotalMemMB 131072 -AvailMemMB 10000 `
                                       -LPs 32 -NetUtil 5.0
            $vmFull  = New-VmMetrics  -Name 'VM-FULL' -HostNode 'NODE1' `
                                      -CpuUtil 100.0 -Procs 4 `
                                      -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $snap    = New-Snapshot -Nodes @($n1Full, $n2Busy) -VMs @($vmFull)

            $result  = Find-MigrationCandidates -Snapshot $snap `
                                                -AggressionLevel 1 -ClusterName 'TEST'
            $result.Count | Should -Be 0
        }

        It 'migrates the same VM at a higher aggression level whose improvement minimum is lower' {
            # Same scenario as above; level-5 minimum is 10, improvement=12.5 ≥ 10  →  migrate
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1Full  = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 `
                                       -TotalMemMB 131072 -AvailMemMB 30000 `
                                       -LPs 32 -NetUtil 10.0
            $n2Busy  = New-HostMetrics -Name 'NODE2' -CpuUtil 80.0 `
                                       -TotalMemMB 131072 -AvailMemMB 10000 `
                                       -LPs 32 -NetUtil 5.0
            $vmFull  = New-VmMetrics  -Name 'VM-FULL' -HostNode 'NODE1' `
                                      -CpuUtil 100.0 -Procs 4 `
                                      -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $snap    = New-Snapshot -Nodes @($n1Full, $n2Busy) -VMs @($vmFull)

            $result  = Find-MigrationCandidates -Snapshot $snap `
                                                -AggressionLevel 5 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }
    }

    # ── Migration plan output fields ───────────────────────────────────────────
    # NODE1 CPU=100%, VM1 cpu=100%, pressure=130  →  score=20.0
    # NODE2 CPU=20%, AvailMem=60000 (> 8192*1.5=12288) → pressure normalises → projected=100.0

    Describe 'Migration plan output' {

        BeforeAll {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $script:migration = $result[0]
        }

        It 'includes VMName' {
            $script:migration.VMName | Should -Be 'VM1'
        }

        It 'includes VMId' {
            $script:migration.VMId | Should -Not -BeNullOrEmpty
        }

        It 'includes SourceNode' {
            $script:migration.SourceNode | Should -Be 'NODE1'
        }

        It 'includes DestinationNode' {
            $script:migration.DestinationNode | Should -Be 'NODE2'
        }

        It 'records the current happiness score' {
            $script:migration.CurrentScore | Should -Be 20.0
        }

        It 'records the projected happiness score after migration' {
            $script:migration.ProjectedScore | Should -Be 100.0
        }

        It 'records the happiness improvement' {
            $script:migration.Improvement | Should -Be 80.0
        }

        It 'records per-dimension happiness before migration' {
            $script:migration.CpuHappinessBefore | Should -Be 0.0
            $script:migration.MemHappinessBefore | Should -Be 40.0
        }

        It 'records per-dimension happiness after migration' {
            $script:migration.CpuHappinessAfter | Should -Be 100.0
            $script:migration.MemHappinessAfter | Should -Be 100.0
        }

        It 'selects the destination with the greatest happiness improvement' {
            # Add a third node (NODE3) that is more loaded than NODE2 → NODE2 should still win
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n3 = New-HostMetrics -Name 'NODE3' -CpuUtil 60.0 `
                                  -TotalMemMB 131072 -AvailMemMB 60000 `
                                  -LPs 32 -NetUtil 5.0
            $snap = New-Snapshot -Nodes @($script:n1, $script:n2, $n3) `
                                 -VMs   @($script:vm1)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count              | Should -Be 1
            $result[0].DestinationNode | Should -Be 'NODE2'   # lower CPU load → higher improvement
        }
    }

    # ── Greedy state update ────────────────────────────────────────────────────
    # Two equally unhappy VMs on NODE1. NODE2 has just enough memory for one of them.
    # After the first migration is planned, the simulated available memory on NODE2
    # drops below the reserve for the second VM  →  only one migration should be planned.
    #
    # NODE2 AvailMem=9000; VM MemAssigned=8192; reserve=512
    # Pass 1:  9000 - 8192 = 808 ≥ 512  →  VM1 planned  →  simAvailMem = 808
    # Pass 2:  808 - 8192 = -7384 < 512  →  VM2 excluded

    Describe 'Greedy state update' {

        It 'accounts for a planned migration when evaluating the next candidate' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1Big = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 `
                                     -TotalMemMB 200000 -AvailMemMB 30000 `
                                     -LPs 32 -NetUtil 10.0
            $n2Snug = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 `
                                      -TotalMemMB 200000 -AvailMemMB 9000 `
                                      -LPs 32 -NetUtil 5.0
            $vmA = New-VmMetrics -Name 'VM-A' -HostNode 'NODE1' `
                                 -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 `
                                 -DynMem $true -Pressure 130.0
            $vmB = New-VmMetrics -Name 'VM-B' -HostNode 'NODE1' `
                                 -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 `
                                 -DynMem $true -Pressure 130.0
            $snap = New-Snapshot -Nodes @($n1Big, $n2Snug) -VMs @($vmA, $vmB)

            $result = Find-MigrationCandidates -Snapshot $snap `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count | Should -Be 1
        }

        It 'does not schedule the same VM twice' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $uniqueVms = $result | Select-Object -ExpandProperty VMName -Unique
            $uniqueVms.Count | Should -Be $result.Count
        }
    }
}
