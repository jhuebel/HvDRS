function Invoke-HvDrsStorageProTipProbe {
    <#
    .SYNOPSIS
        SCOM TimedScript probe entry point: runs an HVDRS storage-DRS recommendation
        pass for a cluster, resolves each recommendation to VMM identities, and
        emits one SCOM property bag per resolvable recommendation for the storage
        ProTip insertion rule to consume.

    .DESCRIPTION
        Orchestrates, but does not reimplement, the existing HVDRS storage pipeline
        — structurally identical to Invoke-HvDrsProTipProbe, adapted for storage:

          Invoke-HvStorageDRS -RecommendOnly -PassThru   (the real scoring/planning
                                                           path — respects maintenance
                                                           lock and storage affinity
                                                           rules exactly like a manual
                                                           or scheduled run)
            -> ConvertTo-HvDrsStorageProTip                (pure translation to PRO Tip fields)
            -> Resolve-VmmStorageIdentity                  (HVDRS identity -> VMM identity)
            -> SCOM property bag                           (one per resolvable recommendation)

        Recommendations that fail VMM identity resolution are skipped (not emitted
        as PRO Tips) and logged via Write-Warning — see Resolve-VmmStorageIdentity's
        fail-soft contract.

        Assumes Invoke-HvStorageDRS (HVDRS module), ConvertTo-HvDrsStorageProTip,
        Resolve-VmmStorageIdentity, and New-HvDrsScriptApi (defined in
        Invoke-HvDrsProTipProbe.ps1) are already loaded into the session — the SCOM
        Run-As script wrapper that calls this function is responsible for
        Import-Module HVDRS and dot-sourcing the sibling ProPack scripts first.

    .PARAMETER ClusterName
        The Failover Cluster to evaluate.

    .PARAMETER VMMServer
        VMM management server to resolve identities against.

    .PARAMETER AggressionLevel
        Passed through to Invoke-HvStorageDRS (default: 3).

    .OUTPUTS
        One or more MOM.ScriptAPI property bag objects, each carrying
        RecommendationCount plus (when RecommendationCount > 0) the full set of
        storage PRO Tip fields for one recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClusterName,

        [string]$VMMServer,

        [ValidateRange(1, 5)]
        [int]$AggressionLevel = 3
    )

    $recommendations = @(Invoke-HvStorageDRS -ClusterName $ClusterName -RecommendOnly -PassThru `
                                              -AggressionLevel $AggressionLevel 6>$null)

    $tips = @($recommendations | ConvertTo-HvDrsStorageProTip)

    $resolvedTips = foreach ($tip in $tips) {
        $identity = Resolve-VmmStorageIdentity -VMId $tip.VMId -DestinationCsvName $tip.DestinationCSVName -VMMServer $VMMServer

        if (-not $identity.Resolved) {
            Write-Warning ("Skipping storage PRO Tip for VM '{0}' ({1} -> {2}): {3}" -f
                $tip.VMName, $tip.SourceCSVName, $tip.DestinationCSVName, $identity.FailureReason)
            continue
        }

        [PSCustomObject]@{
            ClusterName         = $tip.ClusterName
            GeneratedAt         = $tip.GeneratedAt
            VMName              = $tip.VMName
            VMId                = $tip.VMId
            VMMVirtualMachineId = $identity.VirtualMachine.ID
            HostNode            = $tip.HostNode
            SourceCSVName       = $tip.SourceCSVName
            DestinationCSVName  = $tip.DestinationCSVName
            VMMStorageVolumeId  = $identity.StorageVolume.ID
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
        $bag.AddValue('HostNode',               $resolvedTip.HostNode)
        $bag.AddValue('SourceCSVName',          $resolvedTip.SourceCSVName)
        $bag.AddValue('DestinationCSVName',     $resolvedTip.DestinationCSVName)
        $bag.AddValue('VMMStorageVolumeId',     $resolvedTip.VMMStorageVolumeId)
        $bag.AddValue('Title',                  $resolvedTip.Title)
        $bag.AddValue('Description',            $resolvedTip.Description)
        $bag.AddValue('Urgency',                $resolvedTip.Urgency)
        $bag.AddValue('TriggerType',            $resolvedTip.TriggerType)
        $bag.AddValue('Improvement',            $resolvedTip.Improvement)
        Write-Output $bag
    }
}
