<#
.SYNOPSIS
    Orchestration script that runs the full vulnerability-fix pipeline on the
    local Windows machine.

.DESCRIPTION
    Invoke-VulFixes.ps1 ties the four component scripts together into a single
    end-to-end workflow:

      Step 1 – Check-Updates.ps1
               Scans for available Windows, winget, and (optionally) driver
               updates. Saves a JSON report to disk.

      Step 2 – Apply-Updates.ps1
               Downloads and installs the available updates. Sets a
               "RebootRequired" flag when a reboot is needed and notifies
               logged-in users automatically.

      Step 3 – Notify-User.ps1
               Called internally by Apply-Updates.ps1, but can also be invoked
               standalone via the -NotifyOnly switch.

      Step 4 – Enforce-Reboot.ps1
               Enforces the 14-day maximum uptime policy.  Always runs last so
               that newly installed updates are taken into account.

    All four scripts must reside in the same directory as this script.

.PARAMETER ReportPath
    Path for the JSON update report.
    Defaults to "$env:ProgramData\VulFixes\UpdateReport.json".

.PARAMETER IncludeDrivers
    Pass -IncludeDrivers to also check and install driver updates.

.PARAMETER SkipApply
    Run detection only (Check-Updates.ps1) without installing anything.

.PARAMETER SkipChocolatey
    Skip Chocolatey package upgrades even if choco is installed.

.PARAMETER MaxDaysWithoutReboot
    Passed through to Enforce-Reboot.ps1. Defaults to 14.

.PARAMETER GracePeriodMinutes
    Grace period (in minutes) given to users before a forced reboot.
    Defaults to 15.

.PARAMETER ForceReboot
    Immediately trigger a forced reboot (no grace period) after applying
    updates.  Use with caution.

.EXAMPLE
    # Full pipeline with default settings
    .\Invoke-VulFixes.ps1

    # Detection only – do not install anything
    .\Invoke-VulFixes.ps1 -SkipApply

    # Include driver updates and use a 30-minute grace period
    .\Invoke-VulFixes.ps1 -IncludeDrivers -GracePeriodMinutes 30

.NOTES
    Must be run as Administrator.
    Requires Windows 10 / Server 2016 or later.
    Schedule this script with Task Scheduler for automated patching.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ReportPath = "$env:ProgramData\VulFixes\UpdateReport.json",
    [switch]$IncludeDrivers,
    [switch]$SkipApply,
    [switch]$SkipChocolatey,

    [ValidateRange(1, 365)]
    [int]$MaxDaysWithoutReboot = 14,

    [ValidateRange(0, 1440)]
    [int]$GracePeriodMinutes = 15,

    [switch]$ForceReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve component script paths
# ---------------------------------------------------------------------------
$scriptDir          = $PSScriptRoot
$checkScript        = Join-Path $scriptDir 'Check-Updates.ps1'
$applyScript        = Join-Path $scriptDir 'Apply-Updates.ps1'
$notifyScript       = Join-Path $scriptDir 'Notify-User.ps1'
$enforceRebootScript = Join-Path $scriptDir 'Enforce-Reboot.ps1'

foreach ($path in $checkScript, $applyScript, $notifyScript, $enforceRebootScript) {
    if (-not (Test-Path $path)) {
        throw "Required script not found: $path"
    }
}

# ---------------------------------------------------------------------------
# Helper: Print a banner
# ---------------------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    $line = '=' * ($Text.Length + 8)
    Write-Host "`n$line"     -ForegroundColor Magenta
    Write-Host "    $Text   " -ForegroundColor Magenta
    Write-Host "$line`n"     -ForegroundColor Magenta
}

# ---------------------------------------------------------------------------
# Step 1 – Detect available updates
# ---------------------------------------------------------------------------
Write-Banner 'STEP 1: Checking for updates'

$checkParams = @{ ReportPath = $ReportPath }
if ($IncludeDrivers) { $checkParams['IncludeDrivers'] = $true }

& $checkScript @checkParams

# ---------------------------------------------------------------------------
# Step 2 – Apply updates (unless -SkipApply)
# ---------------------------------------------------------------------------
if ($SkipApply) {
    Write-Host "`n-SkipApply specified – skipping update installation." -ForegroundColor Yellow
}
else {
    Write-Banner 'STEP 2: Applying updates'

    $applyParams = @{
        ReportPath       = $ReportPath
        NotifyScriptPath = $notifyScript
    }
    if ($IncludeDrivers)   { $applyParams['IncludeDrivers']   = $true }
    if ($SkipChocolatey)   { $applyParams['SkipChocolatey']   = $true }
    if ($WhatIfPreference) { $applyParams['WhatIf']           = $true }

    & $applyScript @applyParams
}

# ---------------------------------------------------------------------------
# Step 3 – Enforce reboot policy
# ---------------------------------------------------------------------------
Write-Banner 'STEP 3: Enforcing reboot policy'

$rebootParams = @{
    MaxDaysWithoutReboot = $MaxDaysWithoutReboot
    GracePeriodMinutes   = $GracePeriodMinutes
    NotifyScriptPath     = $notifyScript
}
if ($ForceReboot)      { $rebootParams['Force']  = $true }
if ($WhatIfPreference) { $rebootParams['WhatIf'] = $true }

& $enforceRebootScript @rebootParams

Write-Banner 'VulFixes pipeline complete'
