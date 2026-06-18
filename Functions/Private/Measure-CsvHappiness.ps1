function Measure-CsvHappiness {
    <#
    .SYNOPSIS
        Scores a Cluster Shared Volume on a 0–100 Happiness scale.

    .DESCRIPTION
        Two sub-scores are combined according to the caller-supplied weights.

        Space Happiness — based on the percentage of free space:
          >= 40% free  → 100
          20–40% free  → linear 50–100  (50 + (freePct – 20) * 2.5)
          10–20% free  → linear 0–50    ((freePct – 10) * 5)
          < 10% free   → 0

        IO Happiness — based on average disk transfer latency (LatencyMs):
          <= 5 ms   → 100
          5–20 ms   → linear 100–0  (100 – (latency – 5) * 6.667)
          > 20 ms   → 0

          When LatencyMs is $null (counter unavailable), the IO weight is dropped
          and the score normalises to pure space happiness. This ensures no CSV
          is penalised just because performance counters are unavailable.

    .OUTPUTS
        PSCustomObject: CsvName, SpaceHappiness, IoHappiness (nullable), HappinessScore
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $CsvMetrics,

        [ValidateRange(0.0, 1.0)]
        [float] $SpaceWeight = 0.7,

        [ValidateRange(0.0, 1.0)]
        [float] $IoWeight    = 0.3
    )

    # ── Space happiness ────────────────────────────────────────────────────────
    $freePct = if ($CsvMetrics.TotalGB -gt 0) {
        ($CsvMetrics.FreeGB / $CsvMetrics.TotalGB) * 100.0
    } else { 100.0 }

    $spaceHappy = if     ($freePct -ge 40.0) { 100.0 }
                  elseif ($freePct -ge 20.0) { 50.0 + ($freePct - 20.0) * 2.5 }
                  elseif ($freePct -ge 10.0) { ($freePct - 10.0) * 5.0 }
                  else                       { 0.0 }

    # ── IO happiness (latency-based, optional) ─────────────────────────────────
    $ioHappy = $null
    if ($null -ne $CsvMetrics.LatencyMs) {
        $lat     = [float]$CsvMetrics.LatencyMs
        $ioHappy = if     ($lat -le 5.0)  { 100.0 }
                   elseif ($lat -le 20.0) { 100.0 - ($lat - 5.0) * (100.0 / 15.0) }
                   else                   { 0.0 }
    }

    # ── Combined score ─────────────────────────────────────────────────────────
    $effectiveIoWeight = if ($null -ne $ioHappy) { $IoWeight } else { 0.0 }
    $totalWeight       = $SpaceWeight + $effectiveIoWeight

    $score = if ($totalWeight -gt 0) {
        $ioTerm = if ($null -ne $ioHappy) { $ioHappy } else { 0.0 }
        ($spaceHappy * $SpaceWeight + $ioTerm * $effectiveIoWeight) / $totalWeight
    } else { $spaceHappy }

    [PSCustomObject]@{
        CsvName        = $CsvMetrics.Name
        SpaceHappiness = [Math]::Round($spaceHappy, 1)
        IoHappiness    = if ($null -ne $ioHappy) { [Math]::Round($ioHappy, 1) } else { $null }
        HappinessScore = [Math]::Round($score, 1)
    }
}
