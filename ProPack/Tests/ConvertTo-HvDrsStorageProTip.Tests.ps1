#Requires -Module Pester
<#
    Unit tests for ConvertTo-HvDrsStorageProTip.
    Pure function — no SCOM, VMM, FailoverClusters, or Hyper-V dependencies.
#>

BeforeAll {
    . "$PSScriptRoot/../../Tests/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Scripts/ConvertTo-HvDrsStorageProTip.ps1"
}

Describe 'ConvertTo-HvDrsStorageProTip' {

    It 'carries through identity and cluster context fields unchanged' {
        $rec = New-StorageMigrationRecommendation -ClusterName 'PROD-CLUSTER' -VMName 'VM01' `
                                                    -HostNode 'HOST-A' -SourceCSVName 'Volume1' -DestinationCSVName 'Volume2'

        $tip = ConvertTo-HvDrsStorageProTip -Recommendation $rec

        $tip.ClusterName        | Should -Be 'PROD-CLUSTER'
        $tip.VMName             | Should -Be 'VM01'
        $tip.VMId               | Should -Be $rec.VMId
        $tip.HostNode           | Should -Be 'HOST-A'
        $tip.SourceCSVName      | Should -Be 'Volume1'
        $tip.DestinationCSVName | Should -Be 'Volume2'
        $tip.GeneratedAt        | Should -Be $rec.GeneratedAt
    }

    It 'sets TriggerType to Happiness when ComplianceReason is absent' {
        $rec = New-StorageMigrationRecommendation -ComplianceReason $null
        (ConvertTo-HvDrsStorageProTip -Recommendation $rec).TriggerType | Should -Be 'Happiness'
    }

    It 'sets TriggerType to Compliance and includes the reason in the description when present' {
        $rec = New-StorageMigrationRecommendation -ComplianceReason 'Breaks hard storage anti-affinity rule X'

        $tip = ConvertTo-HvDrsStorageProTip -Recommendation $rec

        $tip.TriggerType | Should -Be 'Compliance'
        $tip.Description | Should -Match 'Breaks hard storage anti-affinity rule X'
    }

    It 'bands Urgency as High when Improvement >= 40' {
        $rec = New-StorageMigrationRecommendation -Improvement 45.0
        (ConvertTo-HvDrsStorageProTip -Recommendation $rec).Urgency | Should -Be 'High'
    }

    It 'bands Urgency as Medium when Improvement is between 20 and 40' {
        $rec = New-StorageMigrationRecommendation -Improvement 25.0
        (ConvertTo-HvDrsStorageProTip -Recommendation $rec).Urgency | Should -Be 'Medium'
    }

    It 'bands Urgency as Low when Improvement is below 20' {
        $rec = New-StorageMigrationRecommendation -Improvement 15.0
        (ConvertTo-HvDrsStorageProTip -Recommendation $rec).Urgency | Should -Be 'Low'
    }

    It 'includes the VM name, source, and destination CSV in the title' {
        $rec = New-StorageMigrationRecommendation -VMName 'VM01' -SourceCSVName 'Volume1' -DestinationCSVName 'Volume2'
        $tip = ConvertTo-HvDrsStorageProTip -Recommendation $rec

        $tip.Title | Should -Match 'VM01'
        $tip.Title | Should -Match 'Volume1'
        $tip.Title | Should -Match 'Volume2'
    }

    It 'accepts multiple recommendations via the pipeline' {
        $recs = @(
            New-StorageMigrationRecommendation -VMName 'VM01'
            New-StorageMigrationRecommendation -VMName 'VM02'
        )

        $tips = $recs | ConvertTo-HvDrsStorageProTip

        $tips.Count | Should -Be 2
        $tips[0].VMName | Should -Be 'VM01'
        $tips[1].VMName | Should -Be 'VM02'
    }
}
