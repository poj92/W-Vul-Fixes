<#
.SYNOPSIS
    Deploys the VulFixes patching suite to a Windows machine and registers an
    automated daily scheduled task – the single entry point for MSP deployment.

.DESCRIPTION
    Deploy-VulFixes.ps1 is designed to be pushed out via an RMM tool
    (ConnectWise Automate, N-able N-sight, Datto RMM, Kaseya VSA, etc.) or
    run once during on-boarding. It:

      1. Creates the installation directory and copies all component scripts.
      2. Registers a Windows Event Log source ("VulFixes") so that RMM tools
         can monitor the Application log for patch results.
      3. Optionally installs Chocolatey if it is not already present.
      4. Optionally bootstraps winget (App Installer) on Windows 10 / 11
         machines where it is missing.
      5. Registers a daily scheduled task that runs Invoke-VulFixes.ps1 as
         SYSTEM with the highest privileges.
      6. Performs an optional immediate first run of the full pipeline.

    Use -Uninstall to undo everything this script set up.

.PARAMETER InstallPath
    Destination folder for the VulFixes scripts.
    Defaults to "C:\Program Files\VulFixes".

.PARAMETER TaskName
    Name of the scheduled task to register.
    Defaults to "VulFixes-AutoPatch".

.PARAMETER ScheduleTime
    Daily run time for the scheduled task in HH:mm format.
    Defaults to "02:00".

.PARAMETER IncludeDrivers
    Pass -IncludeDrivers so the scheduled task also updates device drivers.

.PARAMETER MaxDaysWithoutReboot
    Passed to Invoke-VulFixes.ps1. Maximum uptime before a forced reboot.
    Defaults to 14.

.PARAMETER GracePeriodMinutes
    Passed to Invoke-VulFixes.ps1. Warning grace period before forced reboot.
    Defaults to 15.

.PARAMETER InstallChocolatey
    Install Chocolatey package manager if it is not already present.
    Requires internet access to reach chocolatey.org.

.PARAMETER BootstrapWinget
    Attempt to install the App Installer (winget) MSIX package if winget is
    not already available. Requires internet access to reach GitHub releases.

.PARAMETER RunNow
    After deployment, immediately run Invoke-VulFixes.ps1 in the foreground.

.PARAMETER Uninstall
    Remove the scheduled task, installed scripts, and log directory that were
    created by a previous run of this script. Does not uninstall Chocolatey
    or winget.

.EXAMPLE
    # Minimal MSP deployment (copies scripts, creates task, registers event source)
    .\Deploy-VulFixes.ps1

    # Full deployment: Chocolatey bootstrap, immediate first run
    .\Deploy-VulFixes.ps1 -InstallChocolatey -RunNow

    # Custom schedule and install path
    .\Deploy-VulFixes.ps1 -InstallPath "C:\Tools\VulFixes" -ScheduleTime "03:30"

    # Remove everything
    .\Deploy-VulFixes.ps1 -Uninstall

.NOTES
    Must be run as Administrator.
    Compatible with PowerShell 5.1 and later.
    Requires Windows 10 / Server 2016 or later.
    All component scripts (Check-Updates.ps1, Apply-Updates.ps1,
    Notify-User.ps1, Enforce-Reboot.ps1, Invoke-VulFixes.ps1) must be in
    the same directory as this script.
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = 'C:\Program Files\VulFixes',

    [string]$TaskName = 'VulFixes-AutoPatch',

    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$ScheduleTime = '02:00',

    [switch]$IncludeDrivers,

    [ValidateRange(1, 365)]
    [int]$MaxDaysWithoutReboot = 14,

    [ValidateRange(0, 1440)]
    [int]$GracePeriodMinutes = 15,

    [switch]$InstallChocolatey,

    [switch]$BootstrapWinget,

    [switch]$RunNow,

    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EventSource = 'VulFixes'
$LogName     = 'Application'

# Scripts that must be present alongside this deployment script
$ComponentScripts = @(
    'Check-Updates.ps1',
    'Apply-Updates.ps1',
    'Notify-User.ps1',
    'Enforce-Reboot.ps1',
    'Invoke-VulFixes.ps1'
)

# ---------------------------------------------------------------------------
# Helper: Write a coloured section header
# ---------------------------------------------------------------------------
function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Helper: Write a success / info line
# ---------------------------------------------------------------------------
function Write-OK {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# UNINSTALL path
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Section 'Uninstalling VulFixes'

    # Remove scheduled task
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Remove scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-OK "Scheduled task '$TaskName' removed."
        }
    }
    else {
        Write-Host "  Scheduled task '$TaskName' not found – skipping." -ForegroundColor Yellow
    }

    # Remove event log source
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        if ($PSCmdlet.ShouldProcess($EventSource, 'Remove event log source')) {
            [System.Diagnostics.EventLog]::DeleteEventSource($EventSource)
            Write-OK "Event log source '$EventSource' removed."
        }
    }

    # Remove install directory and log directory
    foreach ($dir in $InstallPath, "$env:ProgramData\VulFixes") {
        if (Test-Path $dir) {
            if ($PSCmdlet.ShouldProcess($dir, 'Remove directory')) {
                Remove-Item -Path $dir -Recurse -Force
                Write-OK "Directory '$dir' removed."
            }
        }
    }

    Write-Host "`nUninstall complete." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Validate source scripts exist next to this deployment script
# ---------------------------------------------------------------------------
Write-Section 'Validating source scripts'

foreach ($script in $ComponentScripts) {
    $src = Join-Path $PSScriptRoot $script
    if (-not (Test-Path $src)) {
        throw "Required script not found in source directory: $src`nEnsure all VulFixes scripts are in the same folder as Deploy-VulFixes.ps1."
    }
    Write-OK "Found: $script"
}

# ---------------------------------------------------------------------------
# 2. Create installation directory and copy scripts
# ---------------------------------------------------------------------------
Write-Section 'Installing scripts'

if (-not (Test-Path $InstallPath)) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Create directory')) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    }
}

foreach ($script in $ComponentScripts) {
    $src  = Join-Path $PSScriptRoot $script
    $dest = Join-Path $InstallPath  $script
    if ($PSCmdlet.ShouldProcess($dest, 'Copy script')) {
        Copy-Item -Path $src -Destination $dest -Force
    }
    Write-OK "Copied $script -> $InstallPath"
}

# ---------------------------------------------------------------------------
# 3. Register Windows Event Log source
# ---------------------------------------------------------------------------
Write-Section 'Registering Event Log source'

if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    if ($PSCmdlet.ShouldProcess($EventSource, 'Register event log source')) {
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $LogName)
    }
    Write-OK "Event log source '$EventSource' registered in '$LogName' log."
}
else {
    Write-Host "  Event log source '$EventSource' already exists." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4. Optionally install Chocolatey
# ---------------------------------------------------------------------------
if ($InstallChocolatey) {
    Write-Section 'Chocolatey bootstrap'

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Host "  Chocolatey already installed at: $($choco.Source)" -ForegroundColor Yellow
    }
    else {
        Write-Host '  Installing Chocolatey...'
        if ($PSCmdlet.ShouldProcess('Chocolatey', 'Install via official script')) {
            try {
                # Official Chocolatey install method
                [System.Net.ServicePointManager]::SecurityProtocol = `
                    [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                $installScript = (New-Object System.Net.WebClient).DownloadString(
                    'https://community.chocolatey.org/install.ps1'
                )
                Invoke-Expression $installScript
                Write-OK 'Chocolatey installed successfully.'
            }
            catch {
                Write-Warning "Chocolatey installation failed: $_"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Optionally bootstrap winget
# ---------------------------------------------------------------------------
if ($BootstrapWinget) {
    Write-Section 'Winget bootstrap'

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "  winget already available at: $($winget.Source)" -ForegroundColor Yellow
    }
    else {
        Write-Host '  Attempting to install App Installer (winget) via winget-cli release...'
        if ($PSCmdlet.ShouldProcess('winget', 'Install via GitHub release')) {
            try {
                $apiUrl  = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
                $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
                $asset   = $release.assets | Where-Object { $_.name -like '*.msixbundle' } |
                               Select-Object -First 1
                if ($asset) {
                    $tmpPath = Join-Path $env:TEMP $asset.name
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpPath -UseBasicParsing
                    Add-AppxPackage -Path $tmpPath
                    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
                    Write-OK 'winget (App Installer) installed successfully.'
                }
                else {
                    Write-Warning 'Could not locate winget MSIX asset in the latest release.'
                }
            }
            catch {
                Write-Warning "winget bootstrap failed: $_"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Register the daily scheduled task
# ---------------------------------------------------------------------------
Write-Section 'Registering scheduled task'

$invokeScript = Join-Path $InstallPath 'Invoke-VulFixes.ps1'

# Build the argument string
$argParts = @(
    '-NonInteractive',
    '-ExecutionPolicy Bypass',
    "-File `"$invokeScript`"",
    "-MaxDaysWithoutReboot $MaxDaysWithoutReboot",
    "-GracePeriodMinutes $GracePeriodMinutes"
)
if ($IncludeDrivers) { $argParts += '-IncludeDrivers' }

$taskArgument = $argParts -join ' '

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgument
$trigger   = New-ScheduledTaskTrigger -Daily -At $ScheduleTime
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
$settings  = New-ScheduledTaskSettingsSet `
                 -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
                 -MultipleInstances IgnoreNew `
                 -StartWhenAvailable `
                 -WakeToRun:$false

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
    Register-ScheduledTask -TaskName $TaskName `
        -Action    $action    `
        -Trigger   $trigger   `
        -Principal $principal `
        -Settings  $settings  `
        -Description 'VulFixes: daily automated patching (Windows Update, winget, Chocolatey, drivers).' `
        -Force | Out-Null
}

Write-OK ("Scheduled task '$TaskName' registered – runs daily at $ScheduleTime as SYSTEM.")

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
Write-Section 'Deployment summary'
Write-Host ("  Install path  : $InstallPath")
Write-Host ("  Task name     : $TaskName")
Write-Host ("  Schedule      : daily at $ScheduleTime")
Write-Host ("  Max uptime    : $MaxDaysWithoutReboot day(s)")
Write-Host ("  Grace period  : $GracePeriodMinutes minute(s)")
Write-Host ("  Drivers       : $($IncludeDrivers.IsPresent)")
Write-Host ("  Chocolatey    : $(($null -ne (Get-Command choco -ErrorAction SilentlyContinue)))")
Write-Host ("  winget        : $(($null -ne (Get-Command winget -ErrorAction SilentlyContinue)))")

# Write deployment event to the Application log
try {
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        Write-EventLog -LogName $LogName -Source $EventSource -EntryType Information `
            -EventId 999 -Message "VulFixes deployed on $env:COMPUTERNAME. Task: $TaskName, Schedule: $ScheduleTime."
    }
}
catch {}

# ---------------------------------------------------------------------------
# 8. Optional immediate first run
# ---------------------------------------------------------------------------
if ($RunNow) {
    Write-Section 'Running initial update pipeline'
    $runParams = @{
        MaxDaysWithoutReboot = $MaxDaysWithoutReboot
        GracePeriodMinutes   = $GracePeriodMinutes
    }
    if ($IncludeDrivers) { $runParams['IncludeDrivers'] = $true }
    if ($WhatIfPreference) { $runParams['WhatIf'] = $true }

    & $invokeScript @runParams
}

Write-Host "`nDeployment complete." -ForegroundColor Green
