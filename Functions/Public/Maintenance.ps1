function Enable-HvDRSMaintenance {
    <#
    .SYNOPSIS
        Drops a maintenance lock file that causes HvDRS to skip all live migrations.

    .DESCRIPTION
        Creates the maintenance lock file checked by Invoke-HvDRS at the start of each pass.
        While the file exists, HvDRS will still collect metrics and score VMs but will not
        execute or propose any live migrations.

        Remove the lock with Disable-HvDRSMaintenance when the maintenance window ends.

    .PARAMETER Reason
        Optional free-text reason stored inside the lock file (shown in HvDRS output).

    .PARAMETER LockFile
        Path to the lock file. Must match the -MaintenanceLockFile path used by Invoke-HvDRS.
        Default: $env:ProgramData\HvDRS\maintenance.lock

    .EXAMPLE
        Enable-HvDRSMaintenance -Reason 'Patch Tuesday patching window'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Reason = 'Maintenance window',
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (-not $PSCmdlet.ShouldProcess($LockFile, 'Create maintenance lock file')) { return }

    $dir = Split-Path $LockFile
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $content = "{0} — enabled {1}" -f $Reason, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Set-Content -LiteralPath $LockFile -Value $content -Encoding UTF8

    Write-Host "HvDRS maintenance mode ENABLED."
    Write-Host "  Lock file : $LockFile"
    Write-Host "  Reason    : $Reason"
    Write-Host "  Run Disable-HvDRSMaintenance to resume automatic migrations."
}

function Disable-HvDRSMaintenance {
    <#
    .SYNOPSIS
        Removes the HvDRS maintenance lock file, re-enabling automatic live migrations.

    .PARAMETER LockFile
        Path to the lock file. Must match the -MaintenanceLockFile path used by Invoke-HvDRS.
        Default: $env:ProgramData\HvDRS\maintenance.lock

    .EXAMPLE
        Disable-HvDRSMaintenance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (-not (Test-Path -LiteralPath $LockFile)) {
        Write-Warning "Maintenance lock file not found at '$LockFile'. HvDRS is already active."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($LockFile, 'Remove maintenance lock file')) { return }

    Remove-Item -LiteralPath $LockFile -Force
    Write-Host "HvDRS maintenance mode DISABLED. Automatic migrations will resume on the next pass."
}

function Get-HvDRSMaintenanceStatus {
    <#
    .SYNOPSIS
        Reports whether HvDRS maintenance mode is currently active.

    .PARAMETER LockFile
        Path to the lock file.
        Default: $env:ProgramData\HvDRS\maintenance.lock
    #>
    [CmdletBinding()]
    param(
        [string]$LockFile = (Join-Path (Get-HvDRSDataRoot) 'HvDRS\maintenance.lock')
    )

    if (Test-Path -LiteralPath $LockFile) {
        $content = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            MaintenanceActive = $true
            LockFile          = $LockFile
            Reason            = $content
        }
    } else {
        [PSCustomObject]@{
            MaintenanceActive = $false
            LockFile          = $LockFile
            Reason            = $null
        }
    }
}
