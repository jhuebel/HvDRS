#Requires -Module Pester
<#
    Unit tests for Measure-CsvHappiness.
    No cluster or Hyper-V modules required.
#>

BeforeAll {
    . "$PSScriptRoot/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Functions/Private/Measure-CsvHappiness.ps1"
}

Describe 'Measure-CsvHappiness — Space Happiness' {

    It 'returns 100 when free space is exactly 40%' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 400   # 40% free
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 100.0
    }

    It 'returns 100 when free space is above 40%' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 600   # 60% free
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 100.0
    }

    It 'returns 75 when free space is 30% (midpoint of 20–40% band)' {
        # 50 + (30-20)*2.5 = 75
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 300
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 75.0
    }

    It 'returns 50 when free space is exactly 20%' {
        # 50 + (20-20)*2.5 = 50
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 200
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 50.0
    }

    It 'returns 25 when free space is exactly 15% (midpoint of 10–20% band)' {
        # (15-10)*5 = 25
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 150
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 25.0
    }

    It 'returns 0 when free space is exactly 10%' {
        # (10-10)*5 = 0
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 100
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 0.0
    }

    It 'returns 0 when free space is below 10%' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 50    # 5% free
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.SpaceHappiness | Should -Be 0.0
    }
}

Describe 'Measure-CsvHappiness — IO Happiness (latency)' {

    It 'returns 100 when latency is exactly 5 ms' {
        $csv    = New-CsvMetrics -FreeGB 800 -LatencyMs 5.0
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.IoHappiness | Should -Be 100.0
    }

    It 'returns 100 when latency is below 5 ms' {
        $csv    = New-CsvMetrics -FreeGB 800 -LatencyMs 1.5
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.IoHappiness | Should -Be 100.0
    }

    It 'returns 50 when latency is 12.5 ms (midpoint of 5–20 ms band)' {
        # 100 - (12.5-5) * (100/15) = 100 - 7.5*6.667 = 100 - 50 = 50
        $csv    = New-CsvMetrics -FreeGB 800 -LatencyMs 12.5
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.IoHappiness | Should -BeApproximately 50.0 -Because 'midpoint of degradation band'
    }

    It 'returns 0 when latency is exactly 20 ms' {
        $csv    = New-CsvMetrics -FreeGB 800 -LatencyMs 20.0
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.IoHappiness | Should -BeApproximately 0.0 0.1
    }

    It 'returns 0 when latency is above 20 ms' {
        $csv    = New-CsvMetrics -FreeGB 800 -LatencyMs 35.0
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.IoHappiness | Should -Be 0.0
    }

    It 'IoHappiness is null when LatencyMs is null' {
        $csv    = New-CsvMetrics -FreeGB 800   # LatencyMs defaults to null
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.IoHappiness | Should -BeNullOrEmpty
    }
}

Describe 'Measure-CsvHappiness — fallback to space-only when no I/O data' {

    It 'HappinessScore equals SpaceHappiness when LatencyMs is null regardless of IoWeight' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 300   # 30% free → SpaceHappy=75
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.7 -IoWeight 0.3
        $result.HappinessScore | Should -Be 75.0
        $result.SpaceHappiness | Should -Be 75.0
    }

    It 'does not penalise a CSV when I/O data is absent (score stays at space level)' {
        $csvWith    = New-CsvMetrics -TotalGB 1000 -FreeGB 300 -LatencyMs 25.0   # bad latency
        $csvWithout = New-CsvMetrics -TotalGB 1000 -FreeGB 300                   # no I/O data
        $scoreWith    = (Measure-CsvHappiness -CsvMetrics $csvWith    -SpaceWeight 0.7 -IoWeight 0.3).HappinessScore
        $scoreWithout = (Measure-CsvHappiness -CsvMetrics $csvWithout -SpaceWeight 0.7 -IoWeight 0.3).HappinessScore
        $scoreWithout | Should -BeGreaterThan $scoreWith
    }
}

Describe 'Measure-CsvHappiness — combined score with weights' {

    It 'combines space and IO scores with default weights (0.7 / 0.3)' {
        # SpaceHappy=75 (30% free), IoHappy=100 (2ms latency)
        # expected = (75*0.7 + 100*0.3) / 1.0 = 52.5 + 30 = 82.5
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 300 -LatencyMs 2.0
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.7 -IoWeight 0.3
        $result.HappinessScore | Should -Be 82.5
    }

    It 'returns pure space score when IoWeight is 0' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 300 -LatencyMs 25.0   # terrible latency
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 1.0 -IoWeight 0.0
        $result.HappinessScore | Should -Be 75.0
    }

    It 'returns pure IO score when SpaceWeight is 0 and latency is available' {
        # 5% free → SpaceHappy=0 but we want to test pure I/O weighting
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 800 -LatencyMs 12.5   # IoHappy≈50
        $result = Measure-CsvHappiness -CsvMetrics $csv -SpaceWeight 0.0 -IoWeight 1.0
        $result.HappinessScore | Should -BeApproximately 50.0 0.5
    }

    It 'both components at 100 yield score of 100' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 500 -LatencyMs 1.0
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.HappinessScore | Should -Be 100.0
    }

    It 'both components at 0 yield score of 0' {
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 50 -LatencyMs 30.0   # 5% free, high latency
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.HappinessScore | Should -Be 0.0
    }
}

Describe 'Measure-CsvHappiness — output object' {

    It 'returns an object with CsvName, SpaceHappiness, IoHappiness, HappinessScore' {
        $csv    = New-CsvMetrics
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.PSObject.Properties.Name | Should -Contain 'CsvName'
        $result.PSObject.Properties.Name | Should -Contain 'SpaceHappiness'
        $result.PSObject.Properties.Name | Should -Contain 'IoHappiness'
        $result.PSObject.Properties.Name | Should -Contain 'HappinessScore'
    }

    It 'CsvName matches the input CSV Name' {
        $csv    = New-CsvMetrics -Name 'MyCSV'
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.CsvName | Should -Be 'MyCSV'
    }

    It 'HappinessScore is rounded to one decimal place' {
        # 30% free → SpaceHappy = 50 + 10*2.5 = 75.0 (exact, no rounding needed to verify)
        # Use a case that produces a repeating decimal
        # 22% free → SpaceHappy = 50 + (22-20)*2.5 = 55.0 — still exact; try latency
        $csv    = New-CsvMetrics -TotalGB 1000 -FreeGB 300 -LatencyMs 10.0
        # SpaceHappy=75, IoHappy=100-(10-5)*6.667=66.667
        # combined = (75*0.7 + 66.667*0.3)/1.0 = 52.5+20 = 72.5
        $result = Measure-CsvHappiness -CsvMetrics $csv
        $result.HappinessScore.ToString() | Should -Match '^\d+(\.\d)?$'   # 0 or 1 decimal
    }

    It 'HappinessScore is clamped within 0–100' {
        $csvBest  = New-CsvMetrics -TotalGB 1000 -FreeGB 1000 -LatencyMs 0.1
        $csvWorst = New-CsvMetrics -TotalGB 1000 -FreeGB 1    -LatencyMs 99.0
        (Measure-CsvHappiness -CsvMetrics $csvBest).HappinessScore  | Should -BeLessOrEqual 100.0
        (Measure-CsvHappiness -CsvMetrics $csvWorst).HappinessScore | Should -BeGreaterOrEqual 0.0
    }
}
