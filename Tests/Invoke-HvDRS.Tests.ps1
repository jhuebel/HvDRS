BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"

    # Stub out everything Invoke-HvDRS calls so this test exercises only its
    # own control flow (mode resolution, -PassThru emission) without needing
    # a real cluster, Hyper-V, or performance counters.
    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-AffinityRuleSet { param($Path, $ClusterName) ,@() }
    function Get-HvDRSAutomationOverrideSet { param($Path, $ClusterName) ,@() }
    function Get-ClusterSnapshot {
        param($ClusterName, $SampleCount, $SampleIntervalSeconds)
        New-Snapshot -Nodes @(New-HostMetrics -Name 'NODE1') -VMs @()
    }
    function Move-ClusterVirtualMachineRole { param($Cluster, $Name, $Node, $MigrationType) }
    function Find-MigrationCandidates {
        param($Snapshot, $AggressionLevel, $CpuWeight, $MemoryWeight, $MaxDestinationNetworkUtil,
              $DestinationMemoryReserveMB, $RuleSet, $SoftRuleViolationPenalty, $RuleComplianceBonus, $ClusterName)
        @()
    }

    . "$PSScriptRoot\..\Functions\Public\Invoke-HvDRS.ps1"

    function New-Recommendation {
        param(
            [string] $VMName = 'VM1',
            [string] $SourceNode = 'NODE1',
            [string] $DestinationNode = 'NODE2',
            [object] $ComplianceReason = $null
        )
        [PSCustomObject]@{
            VMName             = $VMName
            VMId               = [System.Guid]::NewGuid().ToString()
            SourceNode         = $SourceNode
            DestinationNode    = $DestinationNode
            CurrentScore       = 20.0
            ProjectedScore     = 80.0
            Improvement        = 60.0
            CpuHappinessBefore = 0.0
            MemHappinessBefore = 40.0
            CpuHappinessAfter  = 100.0
            MemHappinessAfter  = 100.0
            ComplianceReason   = $ComplianceReason
        }
    }
}

Describe 'Invoke-HvDRS -PassThru' {

    It 'emits nothing when -PassThru is omitted, even with recommendations' {
        Mock Find-MigrationCandidates { @(New-Recommendation) }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'emits structured recommendation objects when -PassThru is set with -RecommendOnly' {
        Mock Find-MigrationCandidates { @(New-Recommendation) }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -PassThru 6>$null

        $result.Count | Should -Be 1
        $result[0].ClusterName     | Should -Be 'TEST-CLUSTER'
        $result[0].VMName          | Should -Be 'VM1'
        $result[0].SourceNode      | Should -Be 'NODE1'
        $result[0].DestinationNode | Should -Be 'NODE2'
        $result[0].Improvement     | Should -Be 60.0
        $result[0].GeneratedAt     | Should -BeOfType [DateTime]
    }

    It 'emits nothing (an empty result) when -PassThru is set but the cluster is balanced' {
        Mock Find-MigrationCandidates { @() }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -PassThru 6>$null
        $result | Should -BeNullOrEmpty
    }

    It 'still emits recommendation objects when the maintenance lock is active (only execution is suppressed)' {
        Mock Find-MigrationCandidates { @(New-Recommendation) }
        New-Item -Path 'TestDrive:\HvDRS' -ItemType Directory -Force | Out-Null
        $lockPath = 'TestDrive:\HvDRS\maintenance.lock'
        Set-Content -Path $lockPath -Value 'testing'

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -MaintenanceLockFile $lockPath -PassThru 6>$null
        $result.Count | Should -Be 1
        $result[0].VMName | Should -Be 'VM1'
    }

    It 'still emits structured objects when -PassThru is combined with -WhatIf' {
        Mock Find-MigrationCandidates { @(New-Recommendation) }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -PassThru -WhatIf 6>$null

        $result.Count | Should -Be 1
        $result[0].VMName | Should -Be 'VM1'
    }

    It 'preserves the ComplianceReason field for rule-driven recommendations' {
        Mock Find-MigrationCandidates { @(New-Recommendation -ComplianceReason 'Anti-affinity violation') }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -PassThru 6>$null

        $result[0].ComplianceReason | Should -Be 'Anti-affinity violation'
    }
}

Describe 'Invoke-HvDRS automation-level overrides' {

    It 'recommends but does not migrate a VM pinned to Manual, while still migrating other VMs' {
        Mock Find-MigrationCandidates {
            @(
                (New-Recommendation -VMName 'PINNED-VM' -SourceNode 'NODE1' -DestinationNode 'NODE2'),
                (New-Recommendation -VMName 'AUTO-VM'   -SourceNode 'NODE1' -DestinationNode 'NODE2')
            )
        }
        Mock Get-HvDRSAutomationOverrideSet {
            @([PSCustomObject]@{ ClusterName = 'TEST-CLUSTER'; VMName = 'PINNED-VM'; AutomationLevel = 'Manual' })
        }
        Mock Move-ClusterVirtualMachineRole { }

        $result = Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -PassThru 6>$null

        $result.Count | Should -Be 2   # both still show up as recommendations
        Should -Invoke Move-ClusterVirtualMachineRole -Times 0 -ParameterFilter { $Name -eq 'PINNED-VM' }
        Should -Invoke Move-ClusterVirtualMachineRole -Times 1 -ParameterFilter { $Name -eq 'AUTO-VM' }
    }

    It 'migrates normally when no override applies' {
        Mock Find-MigrationCandidates { @(New-Recommendation -VMName 'VM1') }
        Mock Get-HvDRSAutomationOverrideSet { ,@() }
        Mock Move-ClusterVirtualMachineRole { }

        Invoke-HvDRS -ClusterName 'TEST-CLUSTER' 6>$null | Out-Null

        Should -Invoke Move-ClusterVirtualMachineRole -Times 1
    }
}

Describe 'Invoke-HvDRS notifications' {

    BeforeEach {
        function Send-HvDRSNotification { param($Payload, $WebhookUrl, $WriteEventLog) }
    }

    It 'does not call Send-HvDRSNotification when neither -WebhookUrl nor -WriteEventLog is set' {
        Mock Find-MigrationCandidates { @() }
        Mock Send-HvDRSNotification { }

        Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly 6>$null | Out-Null

        Should -Invoke Send-HvDRSNotification -Times 0
    }

    It 'calls Send-HvDRSNotification with a summary payload when -WebhookUrl is set (balanced cluster)' {
        Mock Find-MigrationCandidates { @() }
        Mock Send-HvDRSNotification { }

        Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -RecommendOnly -WebhookUrl 'https://example.test/hook' 6>$null | Out-Null

        Should -Invoke Send-HvDRSNotification -Times 1 -ParameterFilter {
            $WebhookUrl -eq 'https://example.test/hook' -and $Payload.ClusterName -eq 'TEST-CLUSTER' -and $Payload.RecommendationCount -eq 0
        }
    }

    It 'calls Send-HvDRSNotification once after a normal migration pass with correct counts' {
        Mock Find-MigrationCandidates { @(New-Recommendation -VMName 'VM1') }
        Mock Move-ClusterVirtualMachineRole { }
        Mock Send-HvDRSNotification { }

        Invoke-HvDRS -ClusterName 'TEST-CLUSTER' -WriteEventLog -Confirm:$false 6>$null | Out-Null

        Should -Invoke Send-HvDRSNotification -Times 1 -ParameterFilter {
            $WriteEventLog -eq $true -and $Payload.RecommendationCount -eq 1 -and $Payload.ExecutedCount -eq 1 -and $Payload.FailedCount -eq 0
        }
    }
}
