function Get-HvDRSAutomationOverrideSet {
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$Path        = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\automation-overrides.json')
    )

    # See Get-AffinityRuleSet.ps1 for why the leading comma is applied only on the
    # empty-result branches.
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    try {
        $data      = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $overrides = @($data.Overrides)
        if ($ClusterName) {
            $overrides = @($overrides | Where-Object { $_.ClusterName -eq $ClusterName })
        }
        if ($overrides.Count -eq 0) { return ,@() }
        return $overrides
    } catch {
        Write-Warning "Could not load HVDRS automation overrides from '$Path': $_"
        return ,@()
    }
}

function Save-HvDRSAutomationOverrideSet {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Overrides,
        [string]$Path = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\automation-overrides.json')
    )

    $dir = Split-Path -LiteralPath $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject]@{
        Version     = '1.0'
        LastUpdated = (Get-Date -Format 'o')
        Overrides   = if ($Overrides) { $Overrides } else { @() }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}
