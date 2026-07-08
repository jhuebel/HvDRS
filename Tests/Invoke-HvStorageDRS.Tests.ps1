BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"

    # Stub out everything Invoke-HvStorageDRS calls so this test exercises only
    # its own control flow (mode resolution, automation-override gating) without
    # needing a real cluster, Hyper-V, or CSV storage — mirrors the stubbing
    # pattern used in Tests/Invoke-HvDRS.Tests.ps1.
    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-AffinityRuleSet { param($Path, $ClusterName) ,@() }
    function Get-HvDRSAutomationOverrideSet { param($Path, $ClusterName) ,@() }
    function Get-StorageSnapshot {
        param($ClusterName, $SampleCount, $SampleIntervalSeconds)
        New-StorageSnapshot -CSVs @(New-CsvMetrics -Name 'Volume1') -VMs @()
    }
    function Move-VMStorage { param($ComputerName, $VMName, $DestinationStoragePath) }
    function Find-StorageMigrationCandidates {
        param($Snapshot, $AggressionLevel, $SpaceWeight, $IoWeight, $MinFreeGBReserve,
              $RuleSet, $SoftRuleViolationPenalty, $RuleComplianceBonus)
        @()
    }

    . "$PSScriptRoot\..\Functions\Private\Measure-CsvHappiness.ps1"
    . "$PSScriptRoot\..\Functions\Public\Invoke-HvStorageDRS.ps1"

    function New-StorageRecommendation {
        param(
            [string] $VMName             = 'VM1',
            [string] $HostNode           = 'NODE1',
            [string] $SourceCSVName      = 'Volume1',
            [string] $DestinationCSVName = 'Volume2',
            [string] $DestinationCSV     = 'C:\ClusterStorage\Volume2'
        )
        [PSCustomObject]@{
            VMName             = $VMName
            VMId               = [System.Guid]::NewGuid().ToString()
            HostNode           = $HostNode
            SourceCSV          = 'C:\ClusterStorage\Volume1'
            SourceCSVName      = $SourceCSVName
            DestinationCSV     = $DestinationCSV
            DestinationCSVName = $DestinationCSVName
            VHDCount           = 1
            TotalVhdGB         = 50.0
            SourceFreeGBBefore = 100.0
            SourceFreeGBAfter  = 150.0
            DestFreeGBBefore   = 500.0
            DestFreeGBAfter    = 450.0
            SourceScoreBefore  = 20.0
            SourceScoreAfter   = 80.0
            DestScoreBefore    = 90.0
            DestScoreAfter     = 88.0
            Improvement        = 60.0
            ComplianceReason   = $null
        }
    }
}

Describe 'Invoke-HvStorageDRS automation-level overrides' {

    It 'recommends but does not move a VM pinned to Manual, while still moving other VMs' {
        Mock Find-StorageMigrationCandidates {
            @(
                (New-StorageRecommendation -VMName 'PINNED-VM'),
                (New-StorageRecommendation -VMName 'AUTO-VM')
            )
        }
        Mock Get-HvDRSAutomationOverrideSet {
            @([PSCustomObject]@{ ClusterName = 'TEST-CLUSTER'; VMName = 'PINNED-VM'; AutomationLevel = 'Manual' })
        }
        Mock Move-VMStorage { }

        Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -Confirm:$false 6>$null | Out-Null

        Should -Invoke Move-VMStorage -Times 0 -ParameterFilter { $VMName -eq 'PINNED-VM' }
        Should -Invoke Move-VMStorage -Times 1 -ParameterFilter { $VMName -eq 'AUTO-VM' }
    }

    It 'moves normally when no override applies' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation -VMName 'VM1') }
        Mock Get-HvDRSAutomationOverrideSet { ,@() }
        Mock Move-VMStorage { }

        Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -Confirm:$false 6>$null | Out-Null

        Should -Invoke Move-VMStorage -Times 1
    }

    It 'does not call Move-VMStorage under -RecommendOnly even without an override' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation -VMName 'VM1') }
        Mock Move-VMStorage { }

        Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly 6>$null | Out-Null

        Should -Invoke Move-VMStorage -Times 0
    }
}

Describe 'Invoke-HvStorageDRS notifications' {

    BeforeEach {
        function Send-HvDRSNotification { param($Payload, $WebhookUrl, $WriteEventLog) }
    }

    It 'does not call Send-HvDRSNotification when neither -WebhookUrl nor -WriteEventLog is set' {
        Mock Find-StorageMigrationCandidates { @() }
        Mock Send-HvDRSNotification { }

        Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly 6>$null | Out-Null

        Should -Invoke Send-HvDRSNotification -Times 0
    }

    It 'calls Send-HvDRSNotification with a summary payload when -WebhookUrl is set' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation -VMName 'VM1') }
        Mock Move-VMStorage { }
        Mock Send-HvDRSNotification { }

        Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -WebhookUrl 'https://example.test/hook' -Confirm:$false 6>$null | Out-Null

        Should -Invoke Send-HvDRSNotification -Times 1 -ParameterFilter {
            $WebhookUrl -eq 'https://example.test/hook' -and $Payload.RecommendationCount -eq 1 -and $Payload.ExecutedCount -eq 1
        }
    }
}

Describe 'Invoke-HvStorageDRS -PassThru' {

    It 'emits nothing when -PassThru is omitted, even with recommendations' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation) }

        $result = Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'emits structured recommendation objects when -PassThru is set with -RecommendOnly' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation) }

        $result = Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -PassThru 6>$null

        $result.Count | Should -Be 1
        $result[0].ClusterName        | Should -Be 'TEST-CLUSTER'
        $result[0].VMName             | Should -Be 'VM1'
        $result[0].SourceCSVName      | Should -Be 'Volume1'
        $result[0].DestinationCSVName | Should -Be 'Volume2'
        $result[0].Improvement        | Should -Be 60.0
        $result[0].GeneratedAt        | Should -BeOfType [DateTime]
    }

    It 'emits nothing (an empty result) when -PassThru is set but storage is balanced' {
        Mock Find-StorageMigrationCandidates { @() }

        $result = Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -PassThru 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'still emits structured objects when -PassThru is combined with -WhatIf' {
        Mock Find-StorageMigrationCandidates { @(New-StorageRecommendation) }

        $result = Invoke-HvStorageDRS -ClusterName 'TEST-CLUSTER' -PassThru -WhatIf 6>$null

        $result.Count | Should -Be 1
        $result[0].VMName | Should -Be 'VM1'
    }
}
