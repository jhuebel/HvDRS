function New-HvDrsScriptApi {
    <#
    .SYNOPSIS
        Thin wrapper around the 'MOM.ScriptAPI' COM object so Invoke-HvDrsProTipProbe
        is mockable in unit tests (the real COM object only exists on a server with
        the Operations Manager agent installed).
    #>
    [CmdletBinding()]
    param()
    New-Object -ComObject 'MOM.ScriptAPI'
}

function Invoke-HvDrsProTipProbe {
    <#
    .SYNOPSIS
        SCOM TimedScript probe entry point: runs an HVDRS recommendation pass for a
        cluster, resolves each recommendation to VMM identities, and emits one SCOM
        property bag per resolvable recommendation for the ProTip insertion rule to
        consume.

    .DESCRIPTION
        Orchestrates, but does not reimplement, the existing HVDRS pipeline:

          Invoke-HvDRS -RecommendOnly -PassThru   (the real scoring/planning path —
                                                    respects maintenance lock and
                                                    affinity rules exactly like a
                                                    manual or scheduled HVDRS run)
            -> ConvertTo-HvDrsProTip               (pure translation to PRO Tip fields)
            -> Resolve-VmmIdentity                 (HVDRS identity -> VMM identity)
            -> SCOM property bag                   (one per resolvable recommendation)

        Recommendations that fail VMM identity resolution are skipped (not emitted
        as PRO Tips) and logged via Write-Warning — see Resolve-VmmIdentity's
        fail-soft contract. This is a partial-failure-isolated design: one
        unresolvable VM does not prevent other recommendations in the same pass
        from being surfaced.

        Assumes Invoke-HvDRS (HVDRS module), ConvertTo-HvDrsProTip, and
        Resolve-VmmIdentity are already loaded into the session — the SCOM Run-As
        script wrapper that calls this function is responsible for
        Import-Module HVDRS and dot-sourcing the sibling ProPack scripts first.

    .PARAMETER ClusterName
        The Failover Cluster to evaluate.

    .PARAMETER VMMServer
        VMM management server to resolve identities against. Passed through to
        Resolve-VmmIdentity / Get-SCVirtualMachine / Get-SCVMHost.

    .PARAMETER AggressionLevel
        Passed through to Invoke-HvDRS (default: 3).

    .OUTPUTS
        One or more MOM.ScriptAPI property bag objects, each carrying
        RecommendationCount plus (when RecommendationCount > 0) the full set of
        PRO Tip fields for one recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClusterName,

        [string]$VMMServer,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3
    )

    $recommendations = @(Invoke-HvDRS -ClusterName $ClusterName -RecommendOnly -PassThru `
                                       -AggressionLevel $AggressionLevel 6>$null)

    $tips = @($recommendations | ConvertTo-HvDrsProTip)

    $resolvedTips = foreach ($tip in $tips) {
        $identity = Resolve-VmmIdentity -VMId $tip.VMId -DestinationNodeName $tip.DestinationNode -VMMServer $VMMServer

        if (-not $identity.Resolved) {
            Write-Warning ("Skipping PRO Tip for VM '{0}' ({1} -> {2}): {3}" -f
                $tip.VMName, $tip.SourceNode, $tip.DestinationNode, $identity.FailureReason)
            continue
        }

        [PSCustomObject]@{
            ClusterName         = $tip.ClusterName
            GeneratedAt         = $tip.GeneratedAt
            VMName              = $tip.VMName
            VMId                = $tip.VMId
            VMMVirtualMachineId = $identity.VirtualMachine.ID
            SourceNode          = $tip.SourceNode
            DestinationNode     = $tip.DestinationNode
            VMMHostId           = $identity.VMHost.ID
            Title               = $tip.Title
            Description         = $tip.Description
            Urgency             = $tip.Urgency
            TriggerType         = $tip.TriggerType
            Improvement         = $tip.Improvement
        }
    }

    $api   = New-HvDrsScriptApi
    $count = @($resolvedTips).Count

    if ($count -eq 0) {
        $bag = $api.CreatePropertyBag()
        $bag.AddValue('RecommendationCount', 0)
        Write-Output $bag
        return
    }

    foreach ($resolvedTip in $resolvedTips) {
        $bag = $api.CreatePropertyBag()
        $bag.AddValue('RecommendationCount',    $count)
        $bag.AddValue('ClusterName',            $resolvedTip.ClusterName)
        $bag.AddValue('VMName',                 $resolvedTip.VMName)
        $bag.AddValue('VMId',                   $resolvedTip.VMId)
        $bag.AddValue('VMMVirtualMachineId',    $resolvedTip.VMMVirtualMachineId)
        $bag.AddValue('SourceNode',             $resolvedTip.SourceNode)
        $bag.AddValue('DestinationNode',        $resolvedTip.DestinationNode)
        $bag.AddValue('VMMHostId',              $resolvedTip.VMMHostId)
        $bag.AddValue('Title',                  $resolvedTip.Title)
        $bag.AddValue('Description',            $resolvedTip.Description)
        $bag.AddValue('Urgency',                $resolvedTip.Urgency)
        $bag.AddValue('TriggerType',             $resolvedTip.TriggerType)
        $bag.AddValue('Improvement',            $resolvedTip.Improvement)
        Write-Output $bag
    }
}
