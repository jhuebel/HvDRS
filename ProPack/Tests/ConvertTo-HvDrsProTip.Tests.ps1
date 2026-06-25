#Requires -Module Pester
<#
    Unit tests for ConvertTo-HvDrsProTip.
    Pure function — no SCOM, VMM, FailoverClusters, or Hyper-V dependencies.
#>

BeforeAll {
    . "$PSScriptRoot/../../Tests/Helpers/New-TestObjects.ps1"
    . "$PSScriptRoot/../Scripts/ConvertTo-HvDrsProTip.ps1"
}

Describe 'ConvertTo-HvDrsProTip' {

    It 'carries through identity and cluster context fields unchanged' {
        $rec = New-MigrationRecommendation -ClusterName 'PROD-CLUSTER' -VMName 'VM01' `
                                            -SourceNode 'HOST-A' -DestinationNode 'HOST-B'

        $tip = ConvertTo-HvDrsProTip -Recommendation $rec

        $tip.ClusterName     | Should -Be 'PROD-CLUSTER'
        $tip.VMName          | Should -Be 'VM01'
        $tip.VMId            | Should -Be $rec.VMId
        $tip.SourceNode      | Should -Be 'HOST-A'
        $tip.DestinationNode | Should -Be 'HOST-B'
        $tip.GeneratedAt     | Should -Be $rec.GeneratedAt
    }

    It 'sets TriggerType to Happiness when ComplianceReason is absent' {
        $rec = New-MigrationRecommendation -ComplianceReason $null
        (ConvertTo-HvDrsProTip -Recommendation $rec).TriggerType | Should -Be 'Happiness'
    }

    It 'sets TriggerType to Compliance and includes the reason in the description when present' {
        $rec = New-MigrationRecommendation -ComplianceReason 'Breaks hard anti-affinity rule X'

        $tip = ConvertTo-HvDrsProTip -Recommendation $rec

        $tip.TriggerType   | Should -Be 'Compliance'
        $tip.Description   | Should -Match 'Breaks hard anti-affinity rule X'
    }

    It 'bands Urgency as High when Improvement >= 40' {
        $rec = New-MigrationRecommendation -Improvement 45.0
        (ConvertTo-HvDrsProTip -Recommendation $rec).Urgency | Should -Be 'High'
    }

    It 'bands Urgency as Medium when Improvement is between 20 and 40' {
        $rec = New-MigrationRecommendation -Improvement 25.0
        (ConvertTo-HvDrsProTip -Recommendation $rec).Urgency | Should -Be 'Medium'
    }

    It 'bands Urgency as Low when Improvement is below 20' {
        $rec = New-MigrationRecommendation -Improvement 15.0
        (ConvertTo-HvDrsProTip -Recommendation $rec).Urgency | Should -Be 'Low'
    }

    It 'includes the VM name, source, and destination in the title' {
        $rec = New-MigrationRecommendation -VMName 'VM01' -SourceNode 'HOST-A' -DestinationNode 'HOST-B'
        $tip = ConvertTo-HvDrsProTip -Recommendation $rec

        $tip.Title | Should -Match 'VM01'
        $tip.Title | Should -Match 'HOST-A'
        $tip.Title | Should -Match 'HOST-B'
    }

    It 'accepts multiple recommendations via the pipeline' {
        $recs = @(
            New-MigrationRecommendation -VMName 'VM01'
            New-MigrationRecommendation -VMName 'VM02'
        )

        $tips = $recs | ConvertTo-HvDrsProTip

        $tips.Count | Should -Be 2
        $tips[0].VMName | Should -Be 'VM01'
        $tips[1].VMName | Should -Be 'VM02'
    }
}
