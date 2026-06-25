function ConvertTo-HvDrsProTip {
    <#
    .SYNOPSIS
        Translates an Invoke-HvDRS -PassThru recommendation object into the fields a
        VMM PRO Tip needs: a title, a human-readable justification, and an urgency
        rating — with no SCOM or VMM cmdlet calls of its own.

    .DESCRIPTION
        Pure data mapping, no external dependencies — this is the seam between
        HVDRS's own recommendation schema (ClusterName, VMName, VMId, SourceNode,
        DestinationNode, scores, ComplianceReason) and what a SCOM probe script
        needs to emit as a property bag for the ProTip insertion rule to consume.

        Urgency is banded from Improvement using the same kind of thresholds as
        HVDRS's own aggression levels (see Find-MigrationCandidates.ps1):
          Improvement >= 40 -> High
          Improvement >= 20 -> Medium
          otherwise         -> Low

    .OUTPUTS
        PSCustomObject: ClusterName, GeneratedAt, VMName, VMId, SourceNode,
                        DestinationNode, Title, Description, Urgency, TriggerType,
                        Improvement, CurrentScore, ProjectedScore
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

        $title = "HVDRS recommends migrating '{0}' from '{1}' to '{2}'" -f
                 $Recommendation.VMName, $Recommendation.SourceNode, $Recommendation.DestinationNode

        $description = if ($triggerType -eq 'Compliance') {
            "{0}: happiness {1} -> {2} (+{3}). Trigger: rule compliance — {4}" -f
                $title, $Recommendation.CurrentScore, $Recommendation.ProjectedScore,
                $Recommendation.Improvement, $Recommendation.ComplianceReason
        } else {
            "{0}: happiness {1} -> {2} (+{3}). Trigger: happiness improvement" -f
                $title, $Recommendation.CurrentScore, $Recommendation.ProjectedScore,
                $Recommendation.Improvement
        }

        [PSCustomObject]@{
            ClusterName     = $Recommendation.ClusterName
            GeneratedAt     = $Recommendation.GeneratedAt
            VMName          = $Recommendation.VMName
            VMId            = $Recommendation.VMId
            SourceNode      = $Recommendation.SourceNode
            DestinationNode = $Recommendation.DestinationNode
            Title           = $title
            Description     = $description
            Urgency         = $urgency
            TriggerType     = $triggerType
            Improvement     = $Recommendation.Improvement
            CurrentScore    = $Recommendation.CurrentScore
            ProjectedScore  = $Recommendation.ProjectedScore
        }
    }
}
