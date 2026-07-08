function ConvertTo-HvDrsStorageProTip {
    <#
    .SYNOPSIS
        Translates an Invoke-HvStorageDRS -PassThru recommendation object into the
        fields a VMM PRO Tip needs: a title, a human-readable justification, and an
        urgency rating — with no SCOM or VMM cmdlet calls of its own.

    .DESCRIPTION
        Pure data mapping, no external dependencies — mirrors ConvertTo-HvDrsProTip
        but for storage (CSV-to-CSV) recommendations instead of compute (host-to-host)
        ones. Urgency banding uses the same Improvement thresholds as the compute
        version and as HVDRS's own aggression levels:
          Improvement >= 40 -> High
          Improvement >= 20 -> Medium
          otherwise         -> Low

    .OUTPUTS
        PSCustomObject: ClusterName, GeneratedAt, VMName, VMId, HostNode,
                        SourceCSVName, DestinationCSVName, Title, Description,
                        Urgency, TriggerType, Improvement, SourceScoreBefore/After,
                        DestScoreBefore/After
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Recommendation
    )

    process {
        $triggerType = if ($Recommendation.ComplianceReason) { 'Compliance' } else { 'Happiness' }

        $urgency = if ($Recommendation.Improvement -ge 40) { 'High' }
                   elseif ($Recommendation.Improvement -ge 20) { 'Medium' }
                   else { 'Low' }

        $title = "HVDRS recommends moving '{0}''s storage from '{1}' to '{2}'" -f
                 $Recommendation.VMName, $Recommendation.SourceCSVName, $Recommendation.DestinationCSVName

        $description = if ($triggerType -eq 'Compliance') {
            "{0}: CSV happiness {1} -> {2} (+{3}). Trigger: rule compliance — {4}" -f
                $title, $Recommendation.SourceScoreBefore, $Recommendation.SourceScoreAfter,
                $Recommendation.Improvement, $Recommendation.ComplianceReason
        } else {
            "{0}: CSV happiness {1} -> {2} (+{3}). Trigger: space/IO happiness improvement" -f
                $title, $Recommendation.SourceScoreBefore, $Recommendation.SourceScoreAfter,
                $Recommendation.Improvement
        }

        [PSCustomObject]@{
            ClusterName        = $Recommendation.ClusterName
            GeneratedAt        = $Recommendation.GeneratedAt
            VMName             = $Recommendation.VMName
            VMId               = $Recommendation.VMId
            HostNode           = $Recommendation.HostNode
            SourceCSVName      = $Recommendation.SourceCSVName
            DestinationCSVName = $Recommendation.DestinationCSVName
            Title              = $title
            Description        = $description
            Urgency            = $urgency
            TriggerType        = $triggerType
            Improvement        = $Recommendation.Improvement
            SourceScoreBefore  = $Recommendation.SourceScoreBefore
            SourceScoreAfter   = $Recommendation.SourceScoreAfter
            DestScoreBefore    = $Recommendation.DestScoreBefore
            DestScoreAfter     = $Recommendation.DestScoreAfter
        }
    }
}
