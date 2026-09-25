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

    # Fail closed: a file that exists but can't be read must NOT be treated as
    # "no groups" — rules referencing groups would silently lose those members
    # (so enforced rules would stop covering them), and the next group edit
    # would overwrite the file.
    try {
        $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $data -or -not $data.PSObject.Properties['Groups']) {
            throw "the file has no 'Groups' property"
        }
    } catch {
        throw "Could not read the HVDRS group store '$Path': $_. Refusing to continue without it (rules referencing groups would lose members). Fix or restore the file, or delete it if no groups are needed."
    }

    $groups = @($data.Groups | Where-Object { $null -ne $_ })
    if ($ClusterName) {
        $groups = @($groups | Where-Object { $_.ClusterName -eq $ClusterName })
    }
    if ($groups.Count -eq 0) { return ,@() }
    return $groups
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
