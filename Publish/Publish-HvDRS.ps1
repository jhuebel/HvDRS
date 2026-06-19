#Requires -Version 5.1
<#
.SYNOPSIS
    Stages and publishes the HVDRS module to PowerShell Gallery (or another NuGet repository).

.DESCRIPTION
    1. Reads connection settings from publish.config.json in the same directory.
    2. Validates the module manifest.
    3. Copies the module files to a clean staging directory, excluding items that
       should not be distributed (this script, the config file, the test suite, etc.).
    4. Runs Publish-Module against the staging directory.

    Run with -WhatIf to see what would be staged and published without actually
    uploading anything.

.PARAMETER ConfigPath
    Path to the JSON config file. Defaults to publish.config.json in the same
    directory as this script.

.PARAMETER SkipTests
    Skip running the Pester test suite before publishing.
    Tests are skipped automatically when -WhatIf is used.

.EXAMPLE
    # Dry run — validate and stage without uploading
    .\Publish-HvDRS.ps1 -WhatIf

.EXAMPLE
    # Publish with an alternate config file
    .\Publish-HvDRS.ps1 -ConfigPath D:\secrets\hvdrs-publish.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath  = (Join-Path $PSScriptRoot 'publish.config.json'),
    [switch] $SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Error $Message }

$repoRoot   = Split-Path -Parent $PSScriptRoot   # Publish/ is one level below repo root
$moduleName = 'HVDRS'
$manifestPath = Join-Path $repoRoot 'HVDRS.psd1'

Write-Host ''
Write-Host "HVDRS Publisher" -ForegroundColor White
Write-Host "═══════════════" -ForegroundColor DarkGray
Write-Host "  Repo root : $repoRoot"
Write-Host "  Manifest  : $manifestPath"
Write-Host ''

# ── Step 1: Load config ───────────────────────────────────────────────────────
Write-Step 'Loading publish config...'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Fail ("Config file not found: $ConfigPath`n" +
        "Copy Publish\publish.config.template.json to Publish\publish.config.json " +
        "and fill in your API key. See PUBLISH.md for details.")
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if (-not $config.ApiKey -or $config.ApiKey -eq 'YOUR_POWERSHELL_GALLERY_API_KEY_HERE') {
    Write-Fail "ApiKey is not set in '$ConfigPath'. Edit the file and add your PowerShell Gallery API key."
}

$repository = if ($config.Repository) { $config.Repository } else { 'PSGallery' }
Write-Ok "Config loaded — repository: $repository"

# ── Step 2: Validate manifest ─────────────────────────────────────────────────
Write-Step 'Validating module manifest...'

# Test-ModuleManifest resolves RequiredModules on the local machine, which fails
# on non-Windows hosts (or any machine without FailoverClusters/Hyper-V installed).
# Fall back to Import-PowerShellDataFile for version extraction in that case.
$manifest = $null
try {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    Write-Ok "Manifest valid — $moduleName $($manifest.Version)"
} catch {
    if ($_ -match 'RequiredModules' -or $_ -match 'invalid') {
        $psd1Data = Import-PowerShellDataFile -Path $manifestPath
        $manifest  = [PSCustomObject]@{ Version = [version]$psd1Data.ModuleVersion }
        Write-Warning "Test-ModuleManifest could not resolve RequiredModules on this host (Windows-only modules). Manifest syntax was read successfully."
        Write-Ok "Manifest readable — $moduleName $($manifest.Version)"
    } else {
        throw
    }
}

# ── Step 3: Run tests ─────────────────────────────────────────────────────────
if (-not $SkipTests -and -not $WhatIfPreference) {
    Write-Step 'Running Pester test suite...'

    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.0' })) {
        Write-Warning 'Pester 5 not found — skipping tests. Install with: Install-Module Pester -MinimumVersion 5.0'
    } else {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path         = Join-Path $repoRoot 'Tests'
        $cfg.Output.Verbosity = 'Minimal'
        $cfg.Run.PassThru     = $true

        $result = Invoke-Pester -Configuration $cfg

        if ($result.FailedCount -gt 0) {
            Write-Fail "$($result.FailedCount) test(s) failed. Fix failures before publishing."
        }
        Write-Ok "$($result.PassedCount) test(s) passed."
    }
} elseif ($WhatIfPreference) {
    Write-Host '  [SKIP] Tests skipped in -WhatIf mode.' -ForegroundColor DarkGray
} else {
    Write-Host '  [SKIP] Tests skipped (-SkipTests).' -ForegroundColor DarkGray
}

# ── Step 4: Stage module files ────────────────────────────────────────────────
Write-Step 'Staging module files...'

# Directories and files at the repo root that must NOT be included in the published module
$excludeDirs  = @('Publish', 'Tests', '.git')
$excludeFiles = @('PUBLISH.md', '.gitignore', '.gitattributes')

$stageRoot  = Join-Path ([System.IO.Path]::GetTempPath()) "HvDRS-publish-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$stageModule = Join-Path $stageRoot $moduleName

if ($PSCmdlet.ShouldProcess($stageModule, 'Create staging directory')) {
    New-Item -Path $stageModule -ItemType Directory -Force | Out-Null
}

$items = Get-ChildItem -LiteralPath $repoRoot -Force |
    Where-Object { $_.Name -notin $excludeDirs -and $_.Name -notin $excludeFiles -and $_.Name -ne '.git' }

foreach ($item in $items) {
    if ($PSCmdlet.ShouldProcess($item.FullName, 'Stage for publishing')) {
        if ($item.PSIsContainer) {
            Copy-Item -LiteralPath $item.FullName -Destination $stageModule -Recurse -Force
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $stageModule -Force
        }
    }
}

$stagedCount = if (Test-Path $stageModule) {
    (Get-ChildItem -LiteralPath $stageModule -Recurse -File).Count
} else { 0 }

Write-Ok "Staged $stagedCount file(s) to: $stageModule"

# ── Step 5: Publish ───────────────────────────────────────────────────────────
$publishParams = @{
    Path        = $stageModule
    NuGetApiKey = $config.ApiKey
    Repository  = $repository
    ErrorAction = 'Stop'
}

if ($PSCmdlet.ShouldProcess("$moduleName $($manifest.Version)", "Publish to $repository")) {
    Write-Step "Publishing $moduleName $($manifest.Version) to $repository..."

    try {
        Publish-Module @publishParams
        Write-Ok "Published successfully!"
        Write-Host ''
        Write-Host "  https://www.powershellgallery.com/packages/$moduleName/$($manifest.Version)" -ForegroundColor Cyan
    } finally {
        if (Test-Path $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host ''
    Write-Host '  Staging directory preserved for inspection (WhatIf mode):' -ForegroundColor DarkGray
    Write-Host "  $stageModule" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Staged files:' -ForegroundColor DarkGray
    if (Test-Path $stageModule) {
        Get-ChildItem -LiteralPath $stageModule -Recurse -File |
            ForEach-Object { Write-Host "    $($_.FullName.Replace($stageModule, '.'))" -ForegroundColor DarkGray }
    }
}

Write-Host ''
