# W-Vul-Fixes

This repository contains PowerShell automation scripts for detecting and fixing vulnerabilities on Windows machines. The scripts cover the full patching lifecycle: discovery → remediation → user notification → enforced reboot.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `Check-Updates.ps1` | Scans for available Windows, application (winget), and driver updates |
| `Apply-Updates.ps1` | Downloads and installs pending updates; notifies users if a reboot is needed |
| `Notify-User.ps1` | Displays a pop-up message to every active user session on the machine |
| `Enforce-Reboot.ps1` | Forces a reboot if the system has not been restarted within 14 days |
| `Invoke-VulFixes.ps1` | Orchestration script that runs all four steps in sequence |

---

## Requirements

- Windows 10 / Windows Server 2016 or later
- PowerShell 5.1 or later (PowerShell 7+ recommended)
- Must be run **as Administrator**
- [winget](https://aka.ms/winget) (optional, for application update detection/installation)

---

## Quick Start

Open an elevated PowerShell prompt and run the orchestration script:

```powershell
# Full pipeline – detect, install, notify users, enforce 14-day reboot policy
.\Invoke-VulFixes.ps1

# Detection only (no changes made)
.\Invoke-VulFixes.ps1 -SkipApply

# Include driver updates with a 30-minute reboot grace period
.\Invoke-VulFixes.ps1 -IncludeDrivers -GracePeriodMinutes 30

# Preview what would happen without making changes
.\Invoke-VulFixes.ps1 -WhatIf
```

---

## Individual Scripts

### Check-Updates.ps1

Queries three sources for available updates and saves a JSON report.

```powershell
# Basic scan (Windows updates + winget)
.\Check-Updates.ps1

# Include driver updates; save report to a custom path
.\Check-Updates.ps1 -IncludeDrivers -ReportPath "C:\Temp\report.json"
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ReportPath` | `$env:ProgramData\VulFixes\UpdateReport.json` | Path for the JSON output report |
| `-IncludeDrivers` | `$false` | Also check for driver updates via Windows Update |

---

### Apply-Updates.ps1

Downloads and installs all pending updates discovered by `Check-Updates.ps1`.  
Notifies logged-in users when a reboot is required.

```powershell
# Apply all pending updates
.\Apply-Updates.ps1

# Apply updates including drivers; skip winget upgrades
.\Apply-Updates.ps1 -IncludeDrivers -SkipWinget
```

**Parameters**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ReportPath` | `$env:ProgramData\VulFixes\UpdateReport.json` | Path to the JSON report from `Check-Updates.ps1` |
| `-IncludeDrivers` | `$false` | Also install driver updates |
| `-SkipWinget` | `$false` | Skip winget package upgrades |
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

## Scheduling with Task Scheduler

To run the full pipeline automatically every day at 2 AM:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument '-NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\VulFixes\Invoke-VulFixes.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At '02:00'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

Register-ScheduledTask -TaskName 'VulFixes-DailyPatch' `
    -Action $action -Trigger $trigger -Principal $principal -Force
```

---

## Logs

All scripts write timestamped logs to `$env:ProgramData\VulFixes\`:

| File | Written by |
|------|-----------|
| `UpdateReport.json` | `Check-Updates.ps1` |
| `ApplyUpdates.log` | `Apply-Updates.ps1` |
| `EnforceReboot.log` | `Enforce-Reboot.ps1` |
| `RebootRequired.flag` | `Apply-Updates.ps1` (removed after reboot) |
