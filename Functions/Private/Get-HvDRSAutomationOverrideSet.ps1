function Get-HvDRSAutomationOverrideSet {
    [CmdletBinding()]
    param(
        [string]$ClusterName = '',
        [string]$Path        = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\automation-overrides.json')
    )

    # See Get-AffinityRuleSet.ps1 for why the leading comma is applied only on the
    # empty-result branches.
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }

    # Fail closed: a file that exists but can't be read must NOT be treated as
    # "no overrides" — that would silently un-pin every Manual VM and let the
    # next DRS pass migrate it, and the next Set/Remove would overwrite the file.
    try {
        $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $data -or -not $data.PSObject.Properties['Overrides']) {
            throw "the file has no 'Overrides' property"
        }
    } catch {
        throw "Could not read the HVDRS automation override store '$Path': $_. Refusing to continue without it (Manual pins would be ignored). Fix or restore the file, or delete it if no overrides are needed."
    }

    $overrides = @($data.Overrides | Where-Object { $null -ne $_ })
    if ($ClusterName) {
        $overrides = @($overrides | Where-Object { $_.ClusterName -eq $ClusterName })
    }
    if ($overrides.Count -eq 0) { return ,@() }
    return $overrides
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
