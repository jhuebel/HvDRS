function Get-AffinityRuleSet {
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$Path        = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json')
    )

    # PowerShell collapses a 0-element array to $null when it crosses the function
    # output boundary via a bare `return @()`. The leading comma forces the array
    # to survive so callers always receive a real (possibly empty) collection.
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    try {
        $data  = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $rules = @($data.Rules)
        if ($ClusterName) {
            $rules = @($rules | Where-Object { $_.ClusterName -eq $ClusterName })
        }
        return ,$rules
    } catch {
        Write-Warning "Could not load affinity rules from '$Path': $_"
        return ,@()
    }
}

function Save-AffinityRuleSet {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Rules,
        [string]$Path = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\rules.json')
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
