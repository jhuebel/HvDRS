# HVDRS — Installation Guide

## Prerequisites

### Operating System

- Windows Server 2016, 2019, or 2022 (all cluster nodes)
- PowerShell 5.1 or later (included in all supported Windows Server versions)

### Windows Roles and Features

The following must be installed on **every cluster node**:

| Feature | Install command |
|---|---|
| Hyper-V | `Install-WindowsFeature Hyper-V` |
| Failover Clustering | `Install-WindowsFeature Failover-Clustering` |
| Failover Cluster Management Tools | `Install-WindowsFeature RSAT-Clustering-PowerShell` |
| Hyper-V Management Tools | `Install-WindowsFeature RSAT-Hyper-V-Tools` |

> **Note:** Hyper-V Management Tools are needed on the node where HVDRS runs to invoke `Get-VM`, `Get-VMMemory`, and related cmdlets remotely via `Invoke-Command`.

### Account Permissions

The account used to run HVDRS (interactively or as a scheduled task) requires:

- **Cluster administrative rights** — member of the local Administrators group on all cluster nodes, or granted cluster Full Control in Failover Cluster Manager
- **Live Migration permission** — granted by default to cluster administrators
- **WinRM access** — PowerShell remoting must be enabled on all nodes (`Enable-PSRemoting`)
- **Performance counter access** — local Administrators or Performance Monitor Users group on each node (required for CPU, memory, network, and CSV I/O counters)

### Network Requirements

- WinRM (TCP 5985/5986) reachable between the management host and all cluster nodes
- Live Migration network configured on the cluster (standard cluster requirement)

---

## Installation

### Option 1 — PowerShell Gallery (recommended)

Install directly from [PowerShell Gallery](https://www.powershellgallery.com/packages/HVDRS):

```powershell
# System-wide (requires an elevated prompt)
Install-Module -Name HVDRS -Scope AllUsers

# Current user only (no elevation required)
Install-Module -Name HVDRS -Scope CurrentUser
```

The module is automatically placed in the correct `$env:PSModulePath` location and can be imported immediately:

```powershell
Import-Module HVDRS
```

To update to a newer version later:

```powershell
Update-Module -Name HVDRS
```

### Option 2 — Copy from source

Clone the repository and copy the module folder to a directory in `$env:PSModulePath`. The standard system-wide location is:

```powershell
Copy-Item -Recurse .\HVDRS "C:\Program Files\WindowsPowerShell\Modules\HVDRS"
```

To install for the current user only:

```powershell
Copy-Item -Recurse .\HVDRS "$HOME\Documents\WindowsPowerShell\Modules\HVDRS"
```

Verify the module is discoverable:

```powershell
Get-Module -ListAvailable HVDRS
```

### Option 3 — Import directly from source

If you prefer to keep the module in a custom location, import it by path:

```powershell
Import-Module "C:\Scripts\HVDRS\HVDRS.psd1"
```

Add this line to your PowerShell profile or scheduled task script to load it automatically.

---

## Verify Installation

```powershell
Import-Module HVDRS

# List exported functions
Get-Command -Module HVDRS

# Confirm WinRM is reachable on each node
Get-ClusterNode -Cluster 'YOUR-CLUSTER' | ForEach-Object {
    [PSCustomObject]@{
        Node  = $_.Name
        WinRM = if (Test-WSMan -ComputerName $_.Name -ErrorAction SilentlyContinue) { 'OK' } else { 'FAIL' }
    }
}
```

---

## Data Directory

HVDRS creates one directory on the host where it runs:

| Path | Purpose |
|---|---|
| `$env:ProgramData\HvDRS\` | Data directory created automatically on first use |
| `$env:ProgramData\HvDRS\maintenance.lock` | Maintenance lock file; presence suspends all migrations |
| `$env:ProgramData\HvDRS\rules.json` | Affinity / anti-affinity rule store; shared across all clusters, rules scoped by cluster name |

These files are created automatically as needed. No manual setup is required.

> **Tip:** You can use a custom path for the rule store by passing `-RulesPath` to any affinity rule function or to `Invoke-HvDRS`. This is useful when managing multiple separate clusters from one management host.

---

## Scheduled Task Setup

For production use, deploy HVDRS as a scheduled task on one cluster node (or on a dedicated management host with cluster admin rights).

### Create the compute DRS scheduled task

```powershell
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NonInteractive -WindowStyle Hidden -Command "Import-Module HVDRS; Invoke-HvDRS -ClusterName ''PROD-CLUSTER''"'

$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)

$principal = New-ScheduledTaskPrincipal `
    -UserId     'DOMAIN\svc-hvdrs' `
    -LogonType  Password `
    -RunLevel   Highest

Register-ScheduledTask `
    -TaskName   'HvDRS Balancing Pass' `
    -TaskPath   '\HvDRS\' `
    -Action     $action `
    -Trigger    $trigger `
    -Principal  $principal `
    -Description 'Hyper-V DRS — rebalances cluster VMs every 15 minutes'
```

### Create the storage DRS scheduled task

Storage rebalancing runs less frequently than compute rebalancing. Once per hour is typical for most environments:

```powershell
$storageAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NonInteractive -WindowStyle Hidden -Command "Import-Module HVDRS; Invoke-HvStorageDRS -ClusterName ''PROD-CLUSTER''"'

$storageTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -Once -At (Get-Date)

Register-ScheduledTask `
    -TaskName   'HvDRS Storage Balancing Pass' `
    -TaskPath   '\HvDRS\' `
    -Action     $storageAction `
    -Trigger    $storageTrigger `
    -Principal  $principal `
    -Description 'Hyper-V Storage DRS — rebalances CSV utilization every hour'
```

### Recommend-Only monitoring task (no migrations)

Run a separate, more frequent task that only reports happiness scores without migrating:

```powershell
$monitorAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NonInteractive -WindowStyle Hidden -Command "Import-Module HVDRS; Invoke-HvDRS -ClusterName ''PROD-CLUSTER'' -RecommendOnly" >> C:\Logs\HvDRS\monitor.log 2>&1'

$monitorTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)

Register-ScheduledTask `
    -TaskName  'HvDRS Monitor' `
    -TaskPath  '\HvDRS\' `
    -Action    $monitorAction `
    -Trigger   $monitorTrigger `
    -Principal $principal `
    -Description 'HvDRS monitoring pass — collects and logs VM happiness scores without migrating'
```

---

## Upgrading

1. Import the new version from source to test it: `Import-Module ".\HVDRS\HVDRS.psd1" -Force`
2. Run a `-WhatIf` pass to confirm expected behavior against your cluster.
3. Replace the installed module folder: `Copy-Item -Recurse -Force .\HVDRS "C:\Program Files\WindowsPowerShell\Modules\HVDRS"`
4. Restart any long-running PowerShell sessions that had the old module loaded.

The data directory and rule store at `$env:ProgramData\HvDRS\` are not modified during an upgrade.
