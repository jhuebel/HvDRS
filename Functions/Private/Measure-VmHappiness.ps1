function Measure-VmHappiness {
    <#
    .SYNOPSIS
        Calculates a VM Happiness Score (0–100) based on CPU and memory resource satisfaction.

    .DESCRIPTION
        CPU Happiness:
          A VM is CPU-unhappy when the host is overloaded AND the VM is demanding CPU.
          Host CPU stress ramps linearly from 0 at 70% utilization to 1.0 at 100%.
          Happiness = 100 − (stress × VM CPU demand).

        Memory Happiness (Dynamic Memory):
          Based on Hyper-V Dynamic Memory pressure counter.
          Pressure ≤ 100 → fully happy (VM has what it needs or more).
          Pressure 100–150 → linearly degrades to 0.
          Pressure > 150 → fully unhappy.

        Memory Happiness (Static Memory):
          Proxied from host available memory.
          Host memory utilization ≤ 70% → fully happy.
          70–90% → linearly degrades to 0.
          > 90% → fully unhappy.

    .OUTPUTS
        PSCustomObject with VMName, HostNode, CpuHappiness, MemHappiness, HappinessScore.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VmMetrics,

        [Parameter(Mandatory)]
        [PSCustomObject]$HostMetrics,

        [float]$CpuWeight    = 0.5,
        [float]$MemoryWeight = 0.5
    )

    # ── CPU Happiness ──────────────────────────────────────────────────────────
    # Stress factor: 0 when host ≤ 70%, 1 when host = 100%
    $cpuStress    = [Math]::Max(0.0, ($HostMetrics.CpuUtilization - 70.0) / 30.0)
    $cpuHappiness = [Math]::Max(0.0, [Math]::Min(100.0,
                        100.0 - ($cpuStress * $VmMetrics.CpuUtilization)))

    # ── Memory Happiness ───────────────────────────────────────────────────────
    if ($VmMetrics.DynamicMemoryEnabled) {
        $p = $VmMetrics.MemoryPressure
        $memHappiness = if ($p -le 100) {
            100.0
        } elseif ($p -le 150) {
            100.0 - (($p - 100.0) * 2.0)   # 100 → 0 across the 100–150 range
        } else {
            0.0
        }
    } else {
        # Static memory: proxy from host memory utilization
        $hostMemUtil  = (($HostMetrics.TotalMemoryMB - [Math]::Max(0, $HostMetrics.AvailableMemoryMB)) /
                          $HostMetrics.TotalMemoryMB) * 100.0
        $memHappiness = if ($hostMemUtil -le 70.0) {
            100.0
        } elseif ($hostMemUtil -le 90.0) {
            100.0 - (($hostMemUtil - 70.0) * 5.0)  # 100 → 0 across the 70–90% range
        } else {
            0.0
        }
    }

    $memHappiness = [Math]::Max(0.0, [Math]::Min(100.0, $memHappiness))

    # ── Combined Score ─────────────────────────────────────────────────────────
    $totalWeight = $CpuWeight + $MemoryWeight
    $combined    = (($cpuHappiness * $CpuWeight) + ($memHappiness * $MemoryWeight)) / $totalWeight

    [PSCustomObject]@{
        VMName         = $VmMetrics.VMName
        HostNode       = $VmMetrics.HostNode
        CpuHappiness   = [Math]::Round($cpuHappiness, 1)
        MemHappiness   = [Math]::Round($memHappiness, 1)
        HappinessScore = [Math]::Round($combined, 1)
    }
}
