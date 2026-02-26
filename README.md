# W-Vul-Fixes

This repository contains PowerShell automation scripts for detecting and fixing vulnerabilities on Windows machines. The scripts cover the full patching lifecycle: discovery → remediation → user notification → enforced reboot.

The suite is designed for **MSP deployment** – a single `Deploy-VulFixes.ps1` script copies the components to a target machine, registers a Windows Event Log source (for RMM tool integration), optionally bootstraps Chocolatey or winget, and creates a daily scheduled task that runs everything hands-off as SYSTEM.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `Deploy-VulFixes.ps1` | **MSP entry point** – copies scripts, registers event source, creates scheduled task |
| `Check-Updates.ps1` | Scans for available Windows, winget, Chocolatey, and driver updates |
| `Apply-Updates.ps1` | Downloads and installs pending updates; notifies users if a reboot is needed |
| `Notify-User.ps1` | Displays a pop-up message to every active user session on the machine |
| `Enforce-Reboot.ps1` | Forces a reboot if the system has not been restarted within 14 days |
| `Invoke-VulFixes.ps1` | Orchestration script that runs Check → Apply → Enforce in sequence |

---

## Requirements

- Windows 10 / Windows Server 2016 or later
- PowerShell 5.1 or later (all scripts are PS 5.1 compatible)
- Must be run **as Administrator**
- [winget](https://aka.ms/winget) (optional – auto-installed with `-BootstrapWinget`)
- [Chocolatey](https://chocolatey.org) (optional – auto-installed with `-InstallChocolatey`)

---

## MSP Deployment

Copy the entire folder to the target machine (via RMM file deploy, a UNC share, or any other mechanism), then run `Deploy-VulFixes.ps1` once from an elevated prompt or as an RMM script:

```powershell
# Minimal deployment: copies scripts, registers event source, creates daily task
.\Deploy-VulFixes.ps1

# Full MSP bootstrap: install Chocolatey, then deploy and run immediately
.\Deploy-VulFixes.ps1 -InstallChocolatey -RunNow

# Bootstrap winget on machines where it is missing
.\Deploy-VulFixes.ps1 -BootstrapWinget -RunNow

# Custom install path and schedule (e.g. run at 3:30 AM)
.\Deploy-VulFixes.ps1 -InstallPath "C:\Tools\VulFixes" -ScheduleTime "03:30"

# Include driver updates in every automated run
.\Deploy-VulFixes.ps1 -IncludeDrivers

# Remove everything this script created
.\Deploy-VulFixes.ps1 -Uninstall
```

After deployment the machine will:
- Update **Windows** (via Windows Update Agent COM API)
- Update all **applications and browsers** (via winget `upgrade --all`)
- Update all **Chocolatey packages** (via `choco upgrade all`) if Chocolatey is installed
- Update **device drivers** (via Windows Update) if `-IncludeDrivers` was specified
- **Notify logged-in users** with a pop-up when a reboot is needed
- **Force a reboot** (with a 15-minute grace period) if the machine has not been restarted in 14 days

Results are written to the Windows **Application Event Log** under source `VulFixes` (EventIDs 999–1002), making them visible to any RMM tool that monitors the event log.

**Deploy-VulFixes.ps1 parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InstallPath` | `C:\Program Files\VulFixes` | Where scripts are copied on the target |
| `-TaskName` | `VulFixes-AutoPatch` | Name of the scheduled task |
| `-ScheduleTime` | `02:00` | Daily run time (HH:mm) |
| `-IncludeDrivers` | `$false` | Also update device drivers in every automated run |
| `-MaxDaysWithoutReboot` | `14` | Maximum uptime before a forced reboot |
| `-GracePeriodMinutes` | `15` | Warning time before the forced reboot |
| `-InstallChocolatey` | `$false` | Bootstrap Chocolatey if not present |
| `-BootstrapWinget` | `$false` | Bootstrap winget (App Installer) if not present |
| `-RunNow` | `$false` | Run the full pipeline immediately after deploying |
| `-Uninstall` | `$false` | Remove task, scripts, and log directory |

---

## Quick Start (standalone)

Open an elevated PowerShell prompt and run the orchestration script directly:

```powershell
# Full pipeline – detect, install, notify users, enforce 14-day reboot policy
.\Invoke-VulFixes.ps1

# Detection only (no changes made)
.\Invoke-VulFixes.ps1 -SkipApply

# Include driver updates with a 30-minute reboot grace period
.\Invoke-VulFixes.ps1 -IncludeDrivers -GracePeriodMinutes 30

# Skip Chocolatey upgrades this run
.\Invoke-VulFixes.ps1 -SkipChocolatey

# Preview what would happen without making changes
.\Invoke-VulFixes.ps1 -WhatIf
```

---

## Individual Scripts

### Check-Updates.ps1

Queries four sources for available updates and saves a JSON report.

```powershell
# Basic scan (Windows updates + winget + Chocolatey)
.\Check-Updates.ps1

# Include driver updates; save report to a custom path
.\Check-Updates.ps1 -IncludeDrivers -ReportPath "C:\Temp\report.json"
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ReportPath` | `$env:ProgramData\VulFixes\UpdateReport.json` | Path for the JSON output report |
| `-IncludeDrivers` | `$false` | Also check for driver updates via Windows Update |

**Update sources checked**

| Source | What it covers |
|--------|---------------|
| Windows Update (WUA COM) | OS patches, .NET, Visual C++ runtimes, security fixes |
| winget | Applications, browsers (Edge, Chrome, Firefox), runtimes, fonts |
| Chocolatey | Applications, CLI tools, libraries managed via Chocolatey |
| Windows Update – Drivers | Motherboard, GPU, NIC, storage, and other hardware drivers |

---

### Apply-Updates.ps1

Downloads and installs all pending updates.  
Notifies logged-in users when a reboot is required and writes to the Windows Event Log.

```powershell
# Apply all pending updates
.\Apply-Updates.ps1

# Apply updates including drivers; skip Chocolatey upgrades
.\Apply-Updates.ps1 -IncludeDrivers -SkipChocolatey
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ReportPath` | `$env:ProgramData\VulFixes\UpdateReport.json` | Path to the JSON report |
| `-IncludeDrivers` | `$false` | Also install driver updates |
| `-SkipWinget` | `$false` | Skip winget package upgrades |
| `-SkipChocolatey` | `$false` | Skip Chocolatey package upgrades |
| `-NotifyScriptPath` | `.\Notify-User.ps1` | Path to `Notify-User.ps1` |

---

### Notify-User.ps1

Sends a pop-up dialog to every active interactive user session (console and RDP).

```powershell
# Basic notification
.\Notify-User.ps1 -Message "Please restart your computer to finish installing updates."

# Custom title and auto-dismiss after 5 minutes
.\Notify-User.ps1 -Message "Reboot required." -Title "IT Notice" -TimeoutSeconds 300
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Message` | *(required)* | Body text of the pop-up |
| `-Title` | `IT Notification` | Title bar text |
| `-TimeoutSeconds` | `0` (no timeout) | Auto-dismiss timeout in seconds |

---

### Enforce-Reboot.ps1

Enforces a maximum uptime policy. If the machine has not been rebooted within
`MaxDaysWithoutReboot` days, or if `Apply-Updates.ps1` has set a reboot-required
flag, this script warns users and then triggers a forced reboot after the grace period.

```powershell
# Default: warn users 15 minutes before forcing a reboot at 14-day uptime
.\Enforce-Reboot.ps1

# Custom thresholds
.\Enforce-Reboot.ps1 -MaxDaysWithoutReboot 7 -GracePeriodMinutes 30

# Emergency: reboot immediately with no grace period
.\Enforce-Reboot.ps1 -Force
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-MaxDaysWithoutReboot` | `14` | Maximum uptime (days) before a forced reboot |
| `-GracePeriodMinutes` | `15` | Warning time (minutes) before the forced reboot executes |
| `-FlagPath` | `$env:ProgramData\VulFixes\RebootRequired.flag` | Path to the reboot-required flag file |
| `-NotifyScriptPath` | `.\Notify-User.ps1` | Path to `Notify-User.ps1` |
| `-Force` | `$false` | Skip grace period and reboot immediately |

---

## Manual Task Scheduler setup

If you prefer not to use `Deploy-VulFixes.ps1`, you can register the task manually:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument '-NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\VulFixes\Invoke-VulFixes.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At '02:00'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount

Register-ScheduledTask -TaskName 'VulFixes-AutoPatch' `
    -Action $action -Trigger $trigger -Principal $principal -Force
```

---

## RMM Integration – Event Log

All key events are written to the **Windows Application Event Log** under source `VulFixes`:

| EventID | Level | Meaning |
|---------|-------|---------|
| 999 | Information | VulFixes deployed on this machine |
| 1000 | Information | Apply-Updates started |
| 1001 | Warning | Updates installed – reboot required |
| 1002 | Information | Apply-Updates finished successfully |

Configure your RMM tool to alert on EventID 1001 (reboot required) in the Application log, source `VulFixes`.

---

## Logs

All scripts write timestamped logs to `$env:ProgramData\VulFixes\`:

| File | Written by |
|------|-----------|
| `UpdateReport.json` | `Check-Updates.ps1` |
| `ApplyUpdates.log` | `Apply-Updates.ps1` |
| `EnforceReboot.log` | `Enforce-Reboot.ps1` |
| `RebootRequired.flag` | `Apply-Updates.ps1` (removed after reboot) |
