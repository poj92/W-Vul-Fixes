<#
.SYNOPSIS
    Applies pending Windows updates, winget package upgrades, and driver updates
    on the local machine.

.DESCRIPTION
    Reads the JSON report produced by Check-Updates.ps1 (or re-runs the
    detection inline) and installs:
      1. Windows software updates via the Windows Update Agent COM API
      2. Package updates via winget
      3. Driver updates via the Windows Update Agent COM API (optional)

    After installation the script records whether a reboot is pending and,
    if so, calls Notify-User.ps1 to inform any logged-in users.

.PARAMETER ReportPath
    Path to the JSON report created by Check-Updates.ps1.
    If the file does not exist the script runs detection first.

.PARAMETER IncludeDrivers
    When specified, also installs available driver updates.

.PARAMETER SkipWinget
    When specified, skips winget package upgrades.

.PARAMETER NotifyScriptPath
    Path to Notify-User.ps1 used to alert logged-in users after updates.
    Defaults to the same directory as this script.

.EXAMPLE
    .\Apply-Updates.ps1
    .\Apply-Updates.ps1 -IncludeDrivers -ReportPath "C:\Temp\report.json"

.NOTES
    Must be run as Administrator.
    Requires Windows 10 / Server 2016 or later.
    A reboot may be required after running this script.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ReportPath = "$env:ProgramData\VulFixes\UpdateReport.json",
    [switch]$IncludeDrivers,
    [switch]$SkipWinget,
    [string]$NotifyScriptPath = (Join-Path $PSScriptRoot 'Notify-User.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogPath = "$env:ProgramData\VulFixes\ApplyUpdates.log"

# ---------------------------------------------------------------------------
# Helper: Append a timestamped line to the log file
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Host    $entry   }
    }
}

# ---------------------------------------------------------------------------
# Helper: Ensure log directory exists
# ---------------------------------------------------------------------------
function Initialize-LogDir {
    $dir = Split-Path $LogPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 1. Install Windows software updates
# ---------------------------------------------------------------------------
function Install-WindowsUpdates {
    Write-Log 'Starting Windows Update installation...'

    $rebootRequired = $false

    try {
        $session   = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher  = $session.CreateUpdateSearcher()
        $result    = $searcher.Search('IsInstalled=0 and Type=''Software'' and IsHidden=0')

        if ($result.Updates.Count -eq 0) {
            Write-Log 'No Windows software updates to install.'
            return $false
        }

        $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($update in $result.Updates) {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $toInstall.Add($update) | Out-Null
            Write-Log ("  Queued: {0}" -f $update.Title)
        }

        # Download
        Write-Log ("Downloading {0} update(s)..." -f $toInstall.Count)
        $downloader          = $session.CreateUpdateDownloader()
        $downloader.Updates  = $toInstall
        $downloader.Download() | Out-Null

        # Install
        Write-Log ("Installing {0} update(s)..." -f $toInstall.Count)
        $installer         = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult     = $installer.Install()

        Write-Log ("Installation result code: {0}" -f $installResult.ResultCode)
        $rebootRequired = $installResult.RebootRequired
    }
    catch {
        Write-Log "Windows Update installation failed: $_" 'ERROR'
    }

    return $rebootRequired
}

# ---------------------------------------------------------------------------
# 2. Upgrade packages via winget
# ---------------------------------------------------------------------------
function Install-WingetUpdates {
    Write-Log 'Starting winget package upgrades...'

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Log 'winget not found – skipping.' 'WARN'
        return
    }

    try {
        $output = & winget upgrade --all --accept-package-agreements --accept-source-agreements 2>&1
        $output | ForEach-Object { Write-Log "  [winget] $_" }
        Write-Log 'winget upgrades complete.'
    }
    catch {
        Write-Log "winget upgrade failed: $_" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# 3. Install driver updates
# ---------------------------------------------------------------------------
function Install-DriverUpdates {
    Write-Log 'Starting driver update installation...'

    $rebootRequired = $false

    try {
        $session  = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search('IsInstalled=0 and Type=''Driver'' and IsHidden=0')

        if ($result.Updates.Count -eq 0) {
            Write-Log 'No driver updates to install.'
            return $false
        }

        $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($update in $result.Updates) {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $toInstall.Add($update) | Out-Null
            Write-Log ("  Queued driver: {0}" -f $update.Title)
        }

        $downloader         = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $downloader.Download() | Out-Null

        $installer         = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult     = $installer.Install()

        Write-Log ("Driver installation result code: {0}" -f $installResult.ResultCode)
        $rebootRequired = $installResult.RebootRequired
    }
    catch {
        Write-Log "Driver update installation failed: $_" 'ERROR'
    }

    return $rebootRequired
}

# ---------------------------------------------------------------------------
# 4. Check whether a reboot is already pending (from previous ops)
# ---------------------------------------------------------------------------
function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    if (Test-Path $keys[0]) { return $true }
    if (Test-Path $keys[1]) { return $true }

    # PendingFileRenameOperations
    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { return $true }

    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Initialize-LogDir
Write-Log '====== Apply-Updates.ps1 started ======'

$rebootNeeded = $false

# Windows Updates
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install Windows Updates')) {
    $rebootNeeded = $rebootNeeded -or (Install-WindowsUpdates)
}

# Winget
if (-not $SkipWinget) {
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install Winget Updates')) {
        Install-WingetUpdates
    }
}

# Drivers
if ($IncludeDrivers) {
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install Driver Updates')) {
        $rebootNeeded = $rebootNeeded -or (Install-DriverUpdates)
    }
}

# Consolidate reboot status
$rebootNeeded = $rebootNeeded -or (Test-RebootPending)

if ($rebootNeeded) {
    Write-Log 'A reboot is required to complete the update installation.' 'WARN'

    # Persist reboot-required flag for Enforce-Reboot.ps1
    $flagDir = "$env:ProgramData\VulFixes"
    if (-not (Test-Path $flagDir)) { New-Item -ItemType Directory -Path $flagDir -Force | Out-Null }
    Set-Content -Path "$flagDir\RebootRequired.flag" -Value (Get-Date -Format 'o') -Encoding UTF8

    # Notify logged-in users
    if (Test-Path $NotifyScriptPath) {
        Write-Log 'Notifying logged-in users about the required reboot...'
        & $NotifyScriptPath -Message (
            'Windows updates have been installed on this computer. ' +
            'Please save your work and restart as soon as possible to complete the update process.'
        ) -Title 'Reboot Required – Windows Updates'
    }
    else {
        Write-Log "Notify-User.ps1 not found at '$NotifyScriptPath'. Skipping user notification." 'WARN'
    }
}
else {
    Write-Log 'No reboot required at this time.'
}

Write-Log '====== Apply-Updates.ps1 finished ======'
