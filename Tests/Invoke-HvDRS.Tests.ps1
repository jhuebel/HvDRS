BeforeAll {
    . "$PSScriptRoot\Helpers\New-TestObjects.ps1"

    # Stub out everything Invoke-HvDRS calls so this test exercises only its
    # own control flow (mode resolution, -PassThru emission) without needing
    # a real cluster, Hyper-V, or performance counters.
    function Get-HvDRSDataRoot { 'TestDrive:\' }
    function Get-Cluster { [PSCustomObject]@{ Name = 'TEST-CLUSTER' } }
    function Get-AffinityRuleSet { param($Path, $ClusterName) @() }
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
