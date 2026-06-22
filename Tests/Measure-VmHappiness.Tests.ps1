BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"
    . "$PSScriptRoot\..\Functions\Private\Measure-VmHappiness.ps1"
}

Describe 'Measure-VmHappiness' {

    # ── CPU Happiness ──────────────────────────────────────────────────────────
    # stress = max(0, (hostCpu - 70) / 30)
    # cpuHappiness = max(0, 100 - stress * vmCpu)

    Describe 'CPU Happiness' {

        It 'returns 100 when host CPU is well below the 70% stress threshold' {
            # stress = max(0, (50-70)/30) = 0  →  100 - 0*80 = 100
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 50.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 80.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 100.0
        }

        It 'returns 100 when host CPU is exactly at the stress threshold (70%)' {
            # stress = 0  →  100 regardless of vm demand
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 70.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 100.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 100.0
        }

        It 'degrades linearly when host CPU is 85% and VM demand is 80%' {
            # stress = (85-70)/30 = 0.5  →  100 - 0.5*80 = 60
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 85.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 80.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 60.0
        }

        It 'returns 50 when host CPU is 100% and VM demand is 50%' {
            # stress = 1.0  →  100 - 1.0*50 = 50
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 50.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 50.0
        }

        It 'returns 0 when host CPU is 100% and VM is fully demanding' {
            # stress = 1.0  →  100 - 1.0*100 = 0
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 100.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 0.0
        }

        It 'returns 100 when VM has zero CPU demand even on a fully saturated host' {
            # stress = 1.0, vmCpu = 0  →  100 - 1.0*0 = 100
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 0.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).CpuHappiness | Should -Be 100.0
        }
    }

    # ── Memory Happiness — Dynamic Memory ──────────────────────────────────────
    # Pressure ≤ 100 → 100.  100–150 → 100 - (p-100)*2.  >150 → 0.

    Describe 'Memory Happiness — Dynamic Memory' {

        It 'returns 100 when pressure indicates surplus (< 100)' {
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $true -Pressure 80.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 100.0
        }

        It 'returns 100 when pressure is exactly balanced (100)' {
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $true -Pressure 100.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 100.0
        }

        It 'returns 50 at the midpoint of the degradation range (pressure 125)' {
            # 100 - (125-100)*2 = 50
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $true -Pressure 125.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 50.0
        }

        It 'returns 0 at the upper degradation boundary (pressure 150)' {
            # 100 - (150-100)*2 = 0
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $true -Pressure 150.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 0.0
        }

        It 'returns 0 when pressure is above the upper boundary (> 150)' {
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $true -Pressure 200.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 0.0
        }
    }

    # ── Memory Happiness — Static Memory ──────────────────────────────────────
    # hostMemUtil = ((total - avail) / total) * 100
    # ≤ 70% → 100.  70–90% → 100 - (util-70)*5.  >90% → 0.
    # Test values: TotalMemMB=100000 for clean percentages.

    Describe 'Memory Happiness — Static Memory' {

        It 'returns 100 when host memory utilization is low (40%)' {
            # avail=60000, total=100000  →  util=40%  →  happy=100
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0 -TotalMemMB 100000 -AvailMemMB 60000
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $false
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 100.0
        }

        It 'returns 100 at exactly 70% host memory utilization' {
            # avail=30000, total=100000  →  util=70%  →  happy=100 (boundary)
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0 -TotalMemMB 100000 -AvailMemMB 30000
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $false
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 100.0
        }

        It 'returns 50 at 80% host memory utilization' {
            # avail=20000, total=100000  →  util=80%  →  100 - (80-70)*5 = 50
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0 -TotalMemMB 100000 -AvailMemMB 20000
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $false
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 50.0
        }

        It 'returns 0 at exactly 90% host memory utilization' {
            # avail=10000, total=100000  →  util=90%  →  100 - (90-70)*5 = 0
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0 -TotalMemMB 100000 -AvailMemMB 10000
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $false
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 0.0
        }

        It 'returns 0 above 90% host memory utilization' {
            # avail=5000, total=100000  →  util=95%  →  0
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0 -TotalMemMB 100000 -AvailMemMB 5000
            $vm   = New-VmMetrics  -Name 'VM1' -DynMem $false
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).MemHappiness | Should -Be 0.0
        }
    }

    # ── Combined Score ─────────────────────────────────────────────────────────

    Describe 'Combined Score' {

        It 'returns 100 when both CPU and memory are fully satisfied' {
            # host lightly loaded, pressure balanced  →  (100+100)/2 = 100
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 20.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 30.0 -DynMem $true -Pressure 100.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).HappinessScore | Should -Be 100.0
        }

        It 'averages CPU and memory happiness with equal weights' {
            # host=85% CPU, vmCpu=80%  →  cpuHappy=60
            # pressure=125             →  memHappy=50
            # score = (60*0.5 + 50*0.5) / 1.0 = 55
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 85.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 80.0 -DynMem $true -Pressure 125.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).HappinessScore | Should -Be 55.0
        }

        It 'applies custom weights correctly' {
            # host=85% CPU, vmCpu=80%  →  cpuHappy=60
            # pressure=125             →  memHappy=50
            # score = (60*0.3 + 50*0.7) / 1.0 = 18+35 = 53
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 85.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 80.0 -DynMem $true -Pressure 125.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics -CpuWeight 0.3 -MemoryWeight 0.7).HappinessScore |
                Should -Be 53.0
        }

        It 'honours CPU-only weighting' {
            # host=100% CPU, vmCpu=50%  →  cpuHappy=50
            # pressure=100             →  memHappy=100
            # score = (50*1.0 + 100*0.0) / 1.0 = 50
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 50.0 -DynMem $true -Pressure 100.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics -CpuWeight 1.0 -MemoryWeight 0.0).HappinessScore |
                Should -Be 50.0
        }

        It 'honours memory-only weighting' {
            # host=100% CPU, vmCpu=100%  →  cpuHappy=0
            # pressure=125              →  memHappy=50
            # score = (0*0.0 + 50*1.0) / 1.0 = 50
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 100.0 -DynMem $true -Pressure 125.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics -CpuWeight 0.0 -MemoryWeight 1.0).HappinessScore |
                Should -Be 50.0
        }

        It 'returns 0 when both CPU and memory are fully unhappy' {
            # host=100% CPU, vmCpu=100%  →  cpuHappy=0
            # pressure=200              →  memHappy=0
            $hostMetrics = New-HostMetrics -Name 'N1' -CpuUtil 100.0
            $vm   = New-VmMetrics  -Name 'VM1' -CpuUtil 100.0 -DynMem $true -Pressure 200.0
            (Measure-VmHappiness -VmMetrics $vm -HostMetrics $hostMetrics).HappinessScore | Should -Be 0.0
        }
    }

    # ── Output Object ──────────────────────────────────────────────────────────

    Describe 'Output object' {
        BeforeAll {
            $script:host1  = New-HostMetrics -Name 'NODE1' -CpuUtil 85.0
            $script:vm1    = New-VmMetrics  -Name 'WEB-01' -HostNode 'NODE1' `
                                             -CpuUtil 80.0 -DynMem $true -Pressure 125.0
            $script:result = Measure-VmHappiness -VmMetrics $script:vm1 -HostMetrics $script:host1
        }

        It 'returns an object with VMName' {
            $script:result.VMName | Should -Be 'WEB-01'
        }

        It 'returns an object with HostNode' {
            $script:result.HostNode | Should -Be 'NODE1'
        }

        It 'returns an object with CpuHappiness' {
            $script:result.PSObject.Properties.Name | Should -Contain 'CpuHappiness'
        }

        It 'returns an object with MemHappiness' {
            $script:result.PSObject.Properties.Name | Should -Contain 'MemHappiness'
        }

        It 'returns an object with HappinessScore' {
            $script:result.PSObject.Properties.Name | Should -Contain 'HappinessScore'
        }

        It 'scores are within the valid 0–100 range' {
            $script:result.CpuHappiness   | Should -BeGreaterOrEqual 0
            $script:result.CpuHappiness   | Should -BeLessOrEqual    100
            $script:result.MemHappiness   | Should -BeGreaterOrEqual 0
            $script:result.MemHappiness   | Should -BeLessOrEqual    100
            $script:result.HappinessScore | Should -BeGreaterOrEqual 0
            $script:result.HappinessScore | Should -BeLessOrEqual    100
        }

        It 'rounds scores to one decimal place' {
            # host=85% CPU, vmCpu=80%  →  cpuHappy=60.0 (no rounding needed, but verifies [Math]::Round call)
            $result = Measure-VmHappiness -VmMetrics $script:vm1 -HostMetrics $script:host1
            ($result.CpuHappiness.ToString() -match '^\d+(\.\d)?$') | Should -Be $true
        }
    }
}
