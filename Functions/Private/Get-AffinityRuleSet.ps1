function Get-AffinityRuleSet {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $env:ProgramData 'HvDRS\rules.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        return @($data.Rules)
    } catch {
        Write-Warning "Could not load affinity rules from '$Path': $_"
        return @()
    }
}

function Save-AffinityRuleSet {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Rules,
        [string]$Path = (Join-Path $env:ProgramData 'HvDRS\rules.json')
    )

    $dir = Split-Path -LiteralPath $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject]@{
        Version     = '1.0'
        LastUpdated = (Get-Date -Format 'o')
        Rules       = if ($Rules) { $Rules } else { @() }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}
