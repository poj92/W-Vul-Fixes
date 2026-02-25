<#
.SYNOPSIS
    Enforces a system reboot if the machine has not been restarted within the
    last 14 days, or if a reboot-required flag has been set by Apply-Updates.ps1.

.DESCRIPTION
    This script is designed to run on a schedule (e.g., daily via Task Scheduler).
    It performs the following actions:

      1. Checks the system's last boot time.
      2. Checks for a "RebootRequired" flag file written by Apply-Updates.ps1.
      3. If either condition is met:
           a. Notifies all active users via Notify-User.ps1.
           b. Gives users a configurable grace period (default 15 minutes).
           c. If the machine is still online after the grace period, forces a
              reboot.
      4. Once the reboot-required flag has been present for more than
         $MaxDaysWithoutReboot days the grace period is skipped and an
         immediate forced reboot is initiated.

.PARAMETER MaxDaysWithoutReboot
    Maximum number of days the system can remain running without a reboot.
    Defaults to 14.

.PARAMETER GracePeriodMinutes
    Minutes of warning given to users before the forced reboot fires.
    Defaults to 15.

.PARAMETER FlagPath
    Path to the flag file written by Apply-Updates.ps1.
    Defaults to "$env:ProgramData\VulFixes\RebootRequired.flag".

.PARAMETER NotifyScriptPath
    Path to Notify-User.ps1.
    Defaults to the same directory as this script.

.PARAMETER Force
    Skip the grace period and reboot immediately (useful for emergency patching).

.EXAMPLE
    .\Enforce-Reboot.ps1
    .\Enforce-Reboot.ps1 -MaxDaysWithoutReboot 7 -GracePeriodMinutes 30
    .\Enforce-Reboot.ps1 -Force

.NOTES
    Must be run as Administrator.
    Requires Windows Vista / Server 2008 or later.
    Schedule this script with Task Scheduler to run daily.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 365)]
    [int]$MaxDaysWithoutReboot = 14,

    [ValidateRange(0, 1440)]
    [int]$GracePeriodMinutes = 15,

    [string]$FlagPath = "$env:ProgramData\VulFixes\RebootRequired.flag",

    [string]$NotifyScriptPath = (Join-Path $PSScriptRoot 'Notify-User.ps1'),

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$LogPath = "$env:ProgramData\VulFixes\EnforceReboot.log"

# ---------------------------------------------------------------------------
# Helper: Timestamped log
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Host    $entry   }
    }
}

# ---------------------------------------------------------------------------
# Helper: Notify users
# ---------------------------------------------------------------------------
function Invoke-UserNotification {
    param([string]$Msg, [string]$Ttl, [int]$TimeoutSec = 0)

    if (Test-Path $NotifyScriptPath) {
        $params = @{ Message = $Msg; Title = $Ttl }
        if ($TimeoutSec -gt 0) { $params['TimeoutSeconds'] = $TimeoutSec }
        & $NotifyScriptPath @params
    }
    else {
        Write-Log "Notify-User.ps1 not found at '$NotifyScriptPath'. Skipping notification." 'WARN'
        # Fallback: use msg.exe for console sessions
        try { & msg '*' $Msg 2>&1 | Out-Null } catch {}
    }
}

# ---------------------------------------------------------------------------
# 1. Determine last boot time and uptime
# ---------------------------------------------------------------------------
$lastBoot  = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
$uptime    = (Get-Date) - $lastBoot
$uptimeDays = [math]::Round($uptime.TotalDays, 1)

Write-Log ("Last boot  : {0}" -f $lastBoot.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Log ("Uptime     : {0} day(s)" -f $uptimeDays)
Write-Log ("Max allowed: {0} day(s)" -f $MaxDaysWithoutReboot)

# ---------------------------------------------------------------------------
# 2. Check reboot-required flag
# ---------------------------------------------------------------------------
$flagExists      = Test-Path $FlagPath
$flagAgedays     = 0
$rebootRequiredByFlag = $false

if ($flagExists) {
    $flagWritten      = [datetime](Get-Content $FlagPath -Raw).Trim()
    $flagAgeDays      = [math]::Round(((Get-Date) - $flagWritten).TotalDays, 1)
    $rebootRequiredByFlag = $true
    Write-Log ("Reboot flag: present (age {0} day(s))" -f $flagAgeDays) 'WARN'
}
else {
    Write-Log 'Reboot flag: not present.'
}

# ---------------------------------------------------------------------------
# 3. Decide whether a reboot is needed
# ---------------------------------------------------------------------------
$uptimeExceeded = $uptimeDays -ge $MaxDaysWithoutReboot

if (-not $rebootRequiredByFlag -and -not $uptimeExceeded -and -not $Force) {
    Write-Log 'No reboot required at this time. Exiting.'
    exit 0
}

# ---------------------------------------------------------------------------
# 4. Determine grace period
# ---------------------------------------------------------------------------
# If the flag has been set for longer than MaxDaysWithoutReboot days, or if
# -Force is specified, reboot immediately with no grace period.
$immediateReboot = $Force -or ($flagExists -and $flagAgeDays -ge $MaxDaysWithoutReboot) `
                         -or ($uptimeDays -ge ($MaxDaysWithoutReboot + 1))

$actualGrace = if ($immediateReboot) { 0 } else { $GracePeriodMinutes }

# ---------------------------------------------------------------------------
# 5. Notify users
# ---------------------------------------------------------------------------
if ($actualGrace -gt 0) {
    $warningMsg = (
        "IMPORTANT: This computer requires a restart to apply security updates.`n`n" +
        "Your computer will be automatically restarted in $actualGrace minute(s).`n`n" +
        "Please save all open work now."
    )
    Write-Log ("Notifying users. Forced reboot in {0} minute(s)." -f $actualGrace) 'WARN'
    Invoke-UserNotification -Msg $warningMsg `
                             -Ttl 'Forced Restart Notice' `
                             -TimeoutSec ($actualGrace * 60)
}
else {
    $urgentMsg = (
        "URGENT: This computer is being restarted NOW to apply critical security updates.`n`n" +
        "Please save any unsaved work immediately."
    )
    Write-Log 'Sending immediate reboot notification.' 'WARN'
    Invoke-UserNotification -Msg $urgentMsg -Ttl 'Immediate Restart – Security Updates' -TimeoutSec 60
}

# ---------------------------------------------------------------------------
# 6. Schedule or execute the reboot
# ---------------------------------------------------------------------------
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Reboot system')) {
    Write-Log 'WhatIf mode: reboot would be triggered here.' 'WARN'
    exit 0
}

if ($actualGrace -gt 0) {
    Write-Log ("Waiting {0} minute(s) before forcing reboot..." -f $actualGrace)
    Start-Sleep -Seconds ($actualGrace * 60)
}

Write-Log 'Initiating forced reboot...' 'WARN'

# Remove the flag so the next boot doesn't immediately re-trigger
if ($flagExists) {
    Remove-Item -Path $FlagPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Reboot-required flag removed.'
}

# Use shutdown.exe for a clean, logged reboot
& shutdown.exe /r /f /t 0 /c "Forced restart by VulFixes – security updates require reboot."
