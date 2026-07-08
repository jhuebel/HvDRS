function Test-HvDrsEventLogSourceExists {
    <#
    .SYNOPSIS
        Thin wrapper around [System.Diagnostics.EventLog]::SourceExists so
        Send-HvDRSNotification is mockable in unit tests — EventLog is a
        Windows-only API (it throws PlatformNotSupportedException on Linux/macOS
        dev and CI machines), the same reason ProPack's New-HvDrsScriptApi wraps
        its COM object creation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Source)
    [System.Diagnostics.EventLog]::SourceExists($Source)
}

function Send-HvDRSNotification {
    <#
    .SYNOPSIS
        Best-effort notification of an Invoke-HvDRS / Invoke-HvStorageDRS pass
        completion via webhook POST and/or the Windows Application event log.

    .DESCRIPTION
        Both channels are optional and independently gated; neither ever throws —
        a failed webhook POST or event log write is reported with Write-Warning
        and swallowed, since a notification failure must never turn an otherwise
        successful DRS pass into a reported failure.

    .PARAMETER Payload
        The object to serialize and send. Callers pass a summary object (cluster,
        mode, recommendation/execution counts, violation counts, etc.) — this
        function has no opinion on its shape.

    .PARAMETER WebhookUrl
        If specified, POSTs the payload as JSON to this URL.

    .PARAMETER WriteEventLog
        If specified, writes the payload as JSON to the Application event log
        under source 'HVDRS' (creating the source first if it doesn't exist).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Payload,

        [string]$WebhookUrl,

        [switch]$WriteEventLog
    )

    if ($WebhookUrl) {
        try {
            $body = $Payload | ConvertTo-Json -Depth 10
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "HVDRS webhook notification to '$WebhookUrl' failed: $_"
        }
    }

    if ($WriteEventLog) {
        try {
            $source = 'HVDRS'
            if (-not (Test-HvDrsEventLogSourceExists -Source $source)) {
                New-EventLog -LogName Application -Source $source -ErrorAction Stop
            }
            $message = $Payload | ConvertTo-Json -Depth 10
            Write-EventLog -LogName Application -Source $source -EntryType Information -EventId 1000 -Message $message -ErrorAction Stop
        } catch {
            Write-Warning "HVDRS event log notification failed: $_"
        }
    }
}
