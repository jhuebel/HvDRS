BeforeAll {
    function Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType) }
    function New-EventLog { param($LogName, $Source) }
    function Write-EventLog { param($LogName, $Source, $EntryType, $EventId, $Message) }

    . "$PSScriptRoot\..\Functions\Private\Send-HvDRSNotification.ps1"

    function New-Payload {
        [PSCustomObject]@{ ClusterName = 'TEST-CLUSTER'; Mode = 'AUTO-MIGRATE'; RecommendationCount = 2 }
    }
}

Describe 'Send-HvDRSNotification' {

    It 'does nothing when neither -WebhookUrl nor -WriteEventLog is specified' {
        Mock Invoke-RestMethod { }
        Mock Write-EventLog { }

        Send-HvDRSNotification -Payload (New-Payload)

        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Write-EventLog -Times 0
    }

    It 'POSTs the JSON-serialized payload to -WebhookUrl' {
        Mock Invoke-RestMethod { }

        Send-HvDRSNotification -Payload (New-Payload) -WebhookUrl 'https://example.test/hook'

        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://example.test/hook' -and $Method -eq 'Post' -and $ContentType -eq 'application/json' -and $Body -match 'TEST-CLUSTER'
        }
    }

    It 'warns instead of throwing when the webhook POST fails' {
        Mock Invoke-RestMethod { throw 'connection refused' }

        { Send-HvDRSNotification -Payload (New-Payload) -WebhookUrl 'https://example.test/hook' -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It 'creates the event log source when it does not exist, then writes the entry' {
        Mock Test-HvDrsEventLogSourceExists { $false }
        Mock New-EventLog { }
        Mock Write-EventLog { }

        Send-HvDRSNotification -Payload (New-Payload) -WriteEventLog

        Should -Invoke New-EventLog -Times 1 -ParameterFilter { $Source -eq 'HVDRS' -and $LogName -eq 'Application' }
        Should -Invoke Write-EventLog -Times 1 -ParameterFilter { $Message -match 'TEST-CLUSTER' }
    }

    It 'does not recreate the event log source when it already exists' {
        Mock Test-HvDrsEventLogSourceExists { $true }
        Mock New-EventLog { }
        Mock Write-EventLog { }

        Send-HvDRSNotification -Payload (New-Payload) -WriteEventLog

        Should -Invoke New-EventLog -Times 0
        Should -Invoke Write-EventLog -Times 1
    }

    It 'warns instead of throwing when the event log write fails' {
        Mock Test-HvDrsEventLogSourceExists { $true }
        Mock Write-EventLog { throw 'access denied' }

        { Send-HvDRSNotification -Payload (New-Payload) -WriteEventLog -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It 'sends to both channels when both are specified' {
        Mock Invoke-RestMethod { }
        Mock Test-HvDrsEventLogSourceExists { $true }
        Mock Write-EventLog { }

        Send-HvDRSNotification -Payload (New-Payload) -WebhookUrl 'https://example.test/hook' -WriteEventLog

        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Write-EventLog -Times 1
    }
}
