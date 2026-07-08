# HVDRS — VMM PRO Tips Integration (ProPack)

**Optional.** This directory is a separate, optional add-on. The core HVDRS module has zero dependency on System Center VMM or Operations Manager (SCOM) — `Import-Module HVDRS`, `Invoke-HvDRS`, and `Invoke-HvStorageDRS` work exactly as documented in [docs/USAGE.md](../docs/USAGE.md) whether or not this pack is ever installed.

ProPack surfaces both of HVDRS's DRS engines as **VMM PRO Tips**, so a VMM administrator can see and approve them from inside the VMM console:

- **Compute DRS** (`Invoke-HvDRS`) — VMM executes the approved migration itself (`Move-SCVirtualMachine`); this pack never calls `Move-ClusterVirtualMachineRole`.
- **Storage DRS** (`Invoke-HvStorageDRS`) — VMM executes the approved storage move itself; this pack never calls `Move-VMStorage`.

In both cases, HVDRS has already chosen the destination (including its Network-Aware filter / memory-or-space reserve and affinity-rule impact logic) by the time a PRO Tip is generated — this pack only translates and forwards the recommendation.

---

## Prerequisites

- System Center Virtual Machine Manager (VMM), managing the target Hyper-V Failover Cluster.
- System Center Operations Manager (SCOM), integrated with VMM via the VMM connector. **VMM PRO Tips require this integration** — PRO is not a VMM-only feature.
- The VMM management pack imported into the SCOM management group (confirms the host cluster class this pack's monitors target).
- A server with: the HVDRS PowerShell module installed, the VMM console/PowerShell module (`Get-SCVirtualMachine`, `Get-SCVMHost`, `Get-SCStorageVolume` available), and the SCOM agent — typically the SCOM management server or a management server acting as a proxy for the cluster.
- A Run-As account with:
  - **Cluster-side**: rights to run `Invoke-HvDRS -RecommendOnly` and `Invoke-HvStorageDRS -RecommendOnly` against the target cluster (the same FailoverClusters/Hyper-V read access HVDRS normally requires — see the main [README.md](../README.md) Requirements section). No migration-execution rights are needed here, since this pack only ever calls HVDRS in `-RecommendOnly` mode.
  - **VMM-side**: read access sufficient for `Get-SCVirtualMachine` / `Get-SCVMHost` / `Get-SCStorageVolume` (e.g. VMM Read-Only Administrator, or a custom scoped role). No write/execute rights are needed — VMM itself performs the migration/move after an admin approves the PRO Tip, using its own permissions at that time, not this account's.

---

## Architecture

### Compute pipeline

```
Invoke-HvDRS -RecommendOnly -PassThru     (existing HVDRS recommendation path —
                                            respects maintenance lock and affinity
                                            rules exactly like a manual/scheduled run)
        |
        v
ConvertTo-HvDrsProTip                     (pure mapping: recommendation -> title,
                                            justification text, Urgency banding)
        |
        v
Resolve-VmmIdentity                       (HVDRS VMId/node name -> VMM
                                            SCVirtualMachine/SCVMHost; fails soft —
                                            unresolvable recommendations are
                                            skipped, not surfaced)
        |
        v
SCOM property bag (one per resolvable recommendation, via Invoke-HvDrsProTipProbe)
        |
        v
UnitMonitor (RecommendationCount > 0 -> Warning health state) -> Alert
        |
        v
ProTip insertion rule -> VMM PRO Tip (visible in VMM console)
        |
        v
Admin reviews and approves -> VMM's own Move-SCVirtualMachine executes the move
```

See [Functions/Public/Invoke-HvDRS.ps1](../Functions/Public/Invoke-HvDRS.ps1) for the recommendation engine this pack consumes, unmodified, via `-RecommendOnly -PassThru`.

### Storage pipeline

Exactly the same shape, using the storage-side scripts and its own SCOM monitor/rule (`HvDRS.ProTips.Storage*` in the MP XML) so a storage recommendation never collides with a compute one on the same cluster:

```
Invoke-HvStorageDRS -RecommendOnly -PassThru
        |
        v
ConvertTo-HvDrsStorageProTip              (title/justification for a CSV-to-CSV move)
        |
        v
Resolve-VmmStorageIdentity                (HVDRS VMId/CSV name -> VMM
                                            SCVirtualMachine/storage volume; fails soft)
        |
        v
SCOM property bag (via Invoke-HvDrsStorageProTipProbe)
        |
        v
UnitMonitor (HvDRS.ProTips.StorageRecommendationMonitor) -> Alert
        |
        v
Storage ProTip insertion rule -> VMM PRO Tip
        |
        v
Admin reviews and approves -> VMM's own storage-move job executes the move
```

See [Functions/Public/Invoke-HvStorageDRS.ps1](../Functions/Public/Invoke-HvStorageDRS.ps1) for the recommendation engine this half of the pack consumes, unmodified, via `-RecommendOnly -PassThru`.

---

## Installation

1. **Deploy the scripts.** Copy `ProPack/Scripts/*.ps1` to a path on the server that will run the probes (e.g. `C:\Program Files\HVDRS\ProPack\Scripts`). Ensure `Import-Module HVDRS` succeeds on that server. This includes both the compute scripts (`ConvertTo-HvDrsProTip.ps1`, `Resolve-VmmIdentity.ps1`, `Invoke-HvDrsProTipProbe.ps1`) and the storage scripts (`ConvertTo-HvDrsStorageProTip.ps1`, `Resolve-VmmStorageIdentity.ps1`, `Invoke-HvDrsStorageProTipProbe.ps1`) — the storage probe's script body dot-sources `Invoke-HvDrsProTipProbe.ps1` too, purely to reuse the `New-HvDrsScriptApi` COM wrapper it defines.
2. **Update the script body path.** In `ProPack/ManagementPack/HvDRS.ProTips.mp.xml`, both the compute probe (`HvDRS.ProTips.ProbeModuleType`) and storage probe (`HvDRS.ProTips.StorageProbeModuleType`) embed a `<ScriptBody>` that hardcodes `$HvDrsProPackPath = 'C:\Program Files\HVDRS\ProPack\Scripts'` — update both to match step 1 if you deployed elsewhere.
3. **Confirm VMM-version-specific references.** The MP XML has several elements marked `CONFIRM` in inline comments — the exact VMM management pack ID/version reference, the host cluster class name, the cluster-name/VMM-server property paths, and the PRO Tip insertion write-action type (for both the compute and storage rules — the storage rule's write-action has an additional CONFIRM caveat about whether your VMM PRO framework version exposes a distinct "target storage volume" element). These vary by VMM/SCOM release and must be checked against your management group before import (see the comments in the XML for the exact `Get-SCOMClass`/`Get-SCOMManagementPack` lookups to run).
4. **Import the Management Pack** into SCOM (Operations Console → Administration → Management Packs → Import, or `Import-SCOMManagementPack`).
5. **Configure the Run-As profile** (`HvDRS.ProTips.RunAsProfile`) with the account described under Prerequisites, and associate it with the computers/cluster objects this MP targets — the same profile covers both the compute and storage probes.
6. **Verify discovery.** Confirm the target cluster object (the VMM-discovered host cluster class) appears under Monitoring in the Operations Console with both the `HVDRS Migration Recommendation` and `HVDRS Storage Migration Recommendation` monitors.

---

## Configuration

| Setting | Where | Default | Notes |
|---|---|---|---|
| Probe interval (compute) | MP `IntervalSeconds` (`HvDRS.ProTips.RecommendationMonitor` `Configuration`) | 900s (15 min) | Shorter risks re-recommending a move VMM hasn't finished applying; longer delays detecting new VM unhappiness. Override per-cluster via an MP override if needed. |
| Probe interval (storage) | MP `IntervalSeconds` (`HvDRS.ProTips.StorageRecommendationMonitor` `Configuration`) | 900s (15 min) | A storage move typically takes longer than a live migration — consider a longer interval than the compute monitor's if you override this. |
| Aggression level | MP `AggressionLevel` (either monitor's `Configuration`) | 3 | Passed through to `Invoke-HvDRS`/`Invoke-HvStorageDRS -AggressionLevel`; same semantics as a manual run (see [README.md](../README.md) Aggression Levels table). |
| Urgency banding | `ConvertTo-HvDrsProTip.ps1` / `ConvertTo-HvDrsStorageProTip.ps1` | Improvement ≥ 40 → High, ≥ 20 → Medium, else Low | Hardcoded; edit the script if your environment needs different bands. |
| VMM server | MP `VMMServer` (either monitor's `Configuration`) | Resolved from the VMM target's host property | Passed through to `Resolve-VmmIdentity`/`Resolve-VmmStorageIdentity` and the underlying `Get-SCVirtualMachine`/`Get-SCVMHost`/`Get-SCStorageVolume` calls. |

---

## Testing

### Automated (Pester — no SCOM/VMM/Hyper-V required)

```powershell
Invoke-Pester ./ProPack/Tests/ -Output Detailed
```

Covers:
- `ConvertTo-HvDrsProTip.Tests.ps1` / `ConvertTo-HvDrsStorageProTip.Tests.ps1` — recommendation-to-PRO-Tip field mapping, Urgency banding, Compliance vs. Happiness justification text.
- `Resolve-VmmIdentity.Tests.ps1` — VMId/host-name matching against mocked `Get-SCVirtualMachine`/`Get-SCVMHost`, including short-name-vs-FQDN handling and fail-soft behavior.
- `Resolve-VmmStorageIdentity.Tests.ps1` — VMId/CSV-name matching against mocked `Get-SCVirtualMachine`/`Get-SCStorageVolume` (including Name-vs-Label matching) and fail-soft behavior.
- `Invoke-HvDrsProTipProbe.Tests.ps1` / `Invoke-HvDrsStorageProTipProbe.Tests.ps1` — end-to-end orchestration with all collaborators mocked: zero recommendations, partial identity-resolution failure (one VM skipped, others still emitted), parameter pass-through.

### Manual lab checklist (requires a real SCOM + VMM environment)

These cannot be exercised in CI and must be verified against a lab before relying on this pack in production:

- [ ] MP imports without schema errors; the target host cluster class resolves correctly for your VMM MP version.
- [ ] Both probe scripts execute on schedule under the configured Run-As account; property bag values appear in the Operations Console's monitor state/alert views.
- [ ] A resolvable HVDRS compute recommendation surfaces as a PRO Tip in the VMM console's PRO Tips view.
- [ ] A resolvable HVDRS storage recommendation surfaces as a PRO Tip in the VMM console's PRO Tips view.
- [ ] Approving a compute PRO Tip triggers `Move-SCVirtualMachine` to the HVDRS-chosen destination, and the migration succeeds.
- [ ] Approving a storage PRO Tip triggers VMM's storage-move job to the HVDRS-chosen destination volume, and the move succeeds.
- [ ] No PRO Tip (compute or storage) appears while HVDRS's maintenance lock is active for that cluster.
- [ ] A rule-compliance-driven recommendation's justification text correctly reflects "Compliance" (not "Happiness") in the VMM PRO Tip UI, for both pipelines.
- [ ] Repeated probe cycles do not flood VMM with duplicate PRO Tips for a recommendation already pending approval (validate whether SCOM's monitor state semantics already prevent this before adding extra dedup logic).

Record results and any deviations from this document in Troubleshooting below.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No PRO Tips appear, no alerts in SCOM | Run-As account lacks cluster or VMM read rights; check Operations Console health for the monitor and probe script errors |
| Compute PRO Tip never appears even though HVDRS recommends a move manually | VM or destination host not resolvable in VMM — check `Resolve-VmmIdentity`'s `FailureReason` (surfaced via `Write-Warning` in the probe's SCOM diagnostic log) for a VMId or host-name mismatch |
| Storage PRO Tip never appears even though HVDRS recommends a move manually | VM or destination CSV not resolvable in VMM — check `Resolve-VmmStorageIdentity`'s `FailureReason` for a VMId mismatch or a CSV name that doesn't match any VMM storage volume's Name/Label |
| MP import fails with a schema/reference error | A `CONFIRM`-flagged reference (VMM MP version, class name, write-action type) in `HvDRS.ProTips.mp.xml` doesn't match your installed VMM management pack version |
| Compute PRO Tip approved but migration fails in VMM | This pack does not execute the migration — check VMM's own job log; the failure is in VMM's `Move-SCVirtualMachine`, not in HVDRS or this pack |
| Storage PRO Tip approved but the move fails in VMM | This pack does not execute the move — check VMM's own job log; the failure is in VMM's storage-move job, not in HVDRS or this pack |
