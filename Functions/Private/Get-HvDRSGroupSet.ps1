function Get-HvDRSGroupSet {
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$Path        = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\groups.json')
    )

    # See Get-AffinityRuleSet.ps1 for why the leading comma is applied only on the
    # empty-result branches: it protects a 0-element array from collapsing to $null
    # when it crosses the function output boundary, without comma-protecting a
    # populated array (which would make it cross as a single pipeline object).
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    try {
        $data   = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $groups = @($data.Groups)
        if ($ClusterName) {
            $groups = @($groups | Where-Object { $_.ClusterName -eq $ClusterName })
        }
        if ($groups.Count -eq 0) { return ,@() }
        return $groups
    } catch {
        Write-Warning "Could not load HVDRS groups from '$Path': $_"
        return ,@()
    }
}

function Save-HvDRSGroupSet {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Groups,
        [string]$Path = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\groups.json')
    )

    $dir = Split-Path -LiteralPath $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    [PSCustomObject]@{
        Version     = '1.0'
        LastUpdated = (Get-Date -Format 'o')
        Groups      = if ($Groups) { $Groups } else { @() }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}
