BeforeAll {
    # Stub Get-ClusterOwnerNode so Pester can mock it on machines without the
    # FailoverClusters module installed (e.g. developer workstations / CI agents).
    if (-not (Get-Command Get-ClusterOwnerNode -ErrorAction SilentlyContinue)) {
        function Get-ClusterOwnerNode { [CmdletBinding()] param($Cluster, $Resource, $Group) }
    }

    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"
    . "$PSScriptRoot\..\Functions\Private\Measure-VmHappiness.ps1"
    # Get-MigrationRuleImpact is a runtime dependency of Find-MigrationCandidates
    # itself (called internally whenever -RuleSet is non-empty), so it must be in
    # scope here at the file level — not only inside the one Describe block below
    # that happens to reference it directly — or every other Describe's tests
    # that pass -RuleSet would fail to resolve it.
    . "$PSScriptRoot\..\Functions\Private\Get-MigrationRuleImpact.ps1"
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

        It 'queries possible owners on the VM resource, not the role/group' {
            Mock Get-ClusterOwnerNode {
                [PSCustomObject]@{ OwnerNodes = @([PSCustomObject]@{ Name = 'NODE2' }) }
            }

            $null = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                             -AggressionLevel 3 -ClusterName 'TEST'
            Should -Invoke Get-ClusterOwnerNode -ParameterFilter {
                $Resource -eq 'Virtual Machine VM1'
            }
        }

        It 'treats an empty possible-owner list as all nodes eligible' {
            Mock Get-ClusterOwnerNode { [PSCustomObject]@{ OwnerNodes = @() } }

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST'
            $result.Count              | Should -Be 1
            $result[0].DestinationNode | Should -Be 'NODE2'
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
            $uniqueVms = @($result | Select-Object -ExpandProperty VMName -Unique)
            $uniqueVms.Count | Should -Be $result.Count
        }
    }

    # ── Rule checks see moves planned earlier in the same pass ─────────────────
    Describe 'Rule impact uses simulated placement' {
        # Get-MigrationRuleImpact is already dot-sourced at file scope above
        # (Find-MigrationCandidates depends on it internally); nothing extra
        # needed here since Pass 1 no longer calls Test-AffinityCompliance.

        It 'does not move a second anti-affinity member onto the node a compliance move just used' {
            # DC1 + DC2 (hard anti-affinity) share hot NODE1. Pass 1 moves DC1 to the
            # idle NODE2 (projected 100). In Pass 2, DC2 is still unhappy; evaluated
            # against the ORIGINAL placement, NODE2 would look like a rule *fix*
            # (+bonus → 100) and beat NODE3 (62.5 + 25 = 87.5), co-locating both DCs.
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $hot  = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -AvailMemMB 60000 -LPs 32 -NetUtil 10.0
            $idle = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0  -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $busy = New-HostMetrics -Name 'NODE3' -CpuUtil 80.0  -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $dc1  = New-VmMetrics -Name 'DC1' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $dc2  = New-VmMetrics -Name 'DC2' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $snap = New-Snapshot -Nodes @($hot, $idle, $busy) -VMs @($dc1, $dc2)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'DC AA'; Type = 'VmVmAntiAffinity'; Enforced = $true
                VMs = @('DC1', 'DC2'); Hosts = @(); CSVs = @()
            }

            $result = @(Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                                 -RuleSet @($rule) -ClusterName 'TEST')

            $result.Count | Should -Be 2
            ($result | Where-Object VMName -eq 'DC1').DestinationNode | Should -Be 'NODE2'
            ($result | Where-Object VMName -eq 'DC2').DestinationNode | Should -Be 'NODE3'
        }
    }

    Describe 'ExcludedVMs (Manual-pinned)' {

        It 'does not select an excluded VM for happiness-based migration' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $result = Find-MigrationCandidates -Snapshot $script:baseSnapshot `
                                               -AggressionLevel 3 -ClusterName 'TEST' `
                                               -ExcludedVMs @('VM1')
            $result.Count | Should -Be 0
        }

        It 'still migrates a non-excluded unhappy VM' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $vm2 = New-VmMetrics -Name 'VM2' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 `
                                 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $snap = New-Snapshot -Nodes @($script:n1, $script:n2) -VMs @($script:vm1, $vm2)

            $result = @(Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                                 -ClusterName 'TEST' -ExcludedVMs @('VM1'))
            $result.Count     | Should -Be 1
            $result[0].VMName | Should -Be 'VM2'
        }

        It 'skips an excluded VM as a hard-rule compliance fix and uses a movable VM instead' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $hot  = New-HostMetrics -Name 'NODE1' -CpuUtil 50.0 -AvailMemMB 60000 -LPs 32 -NetUtil 10.0
            $idle = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $dc1  = New-VmMetrics -Name 'DC1' -HostNode 'NODE1' -CpuUtil 10.0
            $dc2  = New-VmMetrics -Name 'DC2' -HostNode 'NODE1' -CpuUtil 10.0
            $snap = New-Snapshot -Nodes @($hot, $idle) -VMs @($dc1, $dc2)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'DC AA'; Type = 'VmVmAntiAffinity'; Enforced = $true
                VMs = @('DC1', 'DC2'); Hosts = @(); CSVs = @()
            }

            $result = @(Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                                 -RuleSet @($rule) -ClusterName 'TEST' `
                                                 -ExcludedVMs @('DC1'))
            $result.Count              | Should -Be 1
            $result[0].VMName          | Should -Be 'DC2'
            $result[0].DestinationNode | Should -Be 'NODE2'
        }

        It 'reports no valid destination (rather than picking the excluded VM) when it is the only violator' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 50.0 -AvailMemMB 60000 -LPs 32 -NetUtil 10.0
            $n2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $pinned = New-VmMetrics -Name 'PINNED' -HostNode 'NODE1' -CpuUtil 10.0
            $snap = New-Snapshot -Nodes @($n1, $n2) -VMs @($pinned)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'NoNode1'; Type = 'VmHostAntiAffinity'; Enforced = $true
                VMs = @('PINNED'); Hosts = @('NODE1'); CSVs = @()
            }

            # Not wrapped in @() at the call site: Find-MigrationCandidates returns
            # ",@()" (a comma-protected empty array) on the no-migrations path, which
            # relies on the assignment's own single-item unwrapping to survive as a
            # true empty array — @(...) around the call would instead re-collect that
            # one stream item into a 1-element array (see Get-AffinityRuleSet.ps1's
            # comment on this same subtlety).
            $result = Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                               -RuleSet @($rule) -ClusterName 'TEST' `
                                               -ExcludedVMs @('PINNED') -Verbose 4>$null
            $result.Count | Should -Be 0
        }
    }

    Describe 'Multi-VM hard-rule compliance (3+ VMs)' {

        It 'resolves a 3-VM hard anti-affinity violation with two moves when one is not enough' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 100.0 -AvailMemMB 60000 -LPs 32 -NetUtil 10.0
            $n2 = New-HostMetrics -Name 'NODE2' -CpuUtil 10.0  -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $n3 = New-HostMetrics -Name 'NODE3' -CpuUtil 50.0  -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $dc1 = New-VmMetrics -Name 'DC1' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $dc2 = New-VmMetrics -Name 'DC2' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $dc3 = New-VmMetrics -Name 'DC3' -HostNode 'NODE1' -CpuUtil 100.0 -Procs 4 -MemAssignMB 8192 -DynMem $true -Pressure 130.0
            $snap = New-Snapshot -Nodes @($n1, $n2, $n3) -VMs @($dc1, $dc2, $dc3)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'DC AA'; Type = 'VmVmAntiAffinity'; Enforced = $true
                VMs = @('DC1', 'DC2', 'DC3'); Hosts = @(); CSVs = @()
            }

            $result = @(Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                                 -RuleSet @($rule) -ClusterName 'TEST')

            # Both compliance moves land, in two separate migrations, and every DC
            # ends up on a distinct node.
            $result.Count | Should -Be 2
            $result | Where-Object { $_.ComplianceReason } | Measure-Object | Select-Object -ExpandProperty Count | Should -Be 2

            $finalHost = @{ DC1 = 'NODE1'; DC2 = 'NODE1'; DC3 = 'NODE1' }
            foreach ($m in $result) { $finalHost[$m.VMName] = $m.DestinationNode }
            (@($finalHost.Values) | Select-Object -Unique).Count | Should -Be 3
        }

        It 'consolidates a 3-VM hard affinity violation with two moves when one is not enough' {
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            # Three lightly-loaded VMs, each alone on its own node, must all share one host.
            $n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $n2 = New-HostMetrics -Name 'NODE2' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $n3 = New-HostMetrics -Name 'NODE3' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $web1 = New-VmMetrics -Name 'WEB1' -HostNode 'NODE1' -CpuUtil 10.0 -Procs 2 -MemAssignMB 4096
            $web2 = New-VmMetrics -Name 'WEB2' -HostNode 'NODE2' -CpuUtil 10.0 -Procs 2 -MemAssignMB 4096
            $web3 = New-VmMetrics -Name 'WEB3' -HostNode 'NODE3' -CpuUtil 10.0 -Procs 2 -MemAssignMB 4096
            $snap = New-Snapshot -Nodes @($n1, $n2, $n3) -VMs @($web1, $web2, $web3)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'WEB Affinity'; Type = 'VmVmAffinity'; Enforced = $true
                VMs = @('WEB1', 'WEB2', 'WEB3'); Hosts = @(); CSVs = @()
            }

            $result = @(Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 `
                                                 -RuleSet @($rule) -ClusterName 'TEST')

            $result.Count | Should -Be 2

            $finalHost = @{ WEB1 = 'NODE1'; WEB2 = 'NODE2'; WEB3 = 'NODE3' }
            foreach ($m in $result) { $finalHost[$m.VMName] = $m.DestinationNode }
            # @(...) wraps the pipeline result again: with exactly one unique value,
            # Select-Object -Unique emits a bare scalar (not a 1-element array), which
            # has no .Count of its own.
            @($finalHost.Values | Select-Object -Unique).Count | Should -Be 1
        }

        It 'does not attempt a rule move for a rule type outside the 4 handled compute types' {
            # A rule of an unrecognized/storage-only type referencing compute VMs
            # must be ignored (severity 0) rather than throwing.
            Mock Get-ClusterOwnerNode { throw 'no constraints' }

            $n1 = New-HostMetrics -Name 'NODE1' -CpuUtil 20.0 -AvailMemMB 60000 -LPs 32 -NetUtil 5.0
            $vm1 = New-VmMetrics -Name 'VM1' -HostNode 'NODE1' -CpuUtil 10.0
            $snap = New-Snapshot -Nodes @($n1) -VMs @($vm1)
            $rule = [PSCustomObject]@{
                RuleId = 'r1'; Name = 'Irrelevant'; Type = 'VmCsvAffinity'; Enforced = $true
                VMs = @('VM1'); Hosts = @(); CSVs = @('Volume1')
            }

            { Find-MigrationCandidates -Snapshot $snap -AggressionLevel 3 -RuleSet @($rule) -ClusterName 'TEST' } |
                Should -Not -Throw
        }
    }
}
