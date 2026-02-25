<#
.SYNOPSIS
    Scans the local Windows machine for available updates across Windows Update,
    installed applications (winget), and device drivers, then outputs a report.

.DESCRIPTION
    This script queries three sources for available updates:
      1. Windows Update (via the Windows Update Agent COM API)
      2. Installed packages / applications (via winget, if available)
      3. Device drivers (via Get-WindowsDriver / PnPUtil)

    The results are written to the console and optionally saved to a JSON report
    file so that Apply-Updates.ps1 can consume them.

.PARAMETER ReportPath
    Optional path for the JSON output report.
    Defaults to "$env:ProgramData\VulFixes\UpdateReport.json".

.PARAMETER IncludeDrivers
    When specified, also checks for driver updates via Windows Update.

.EXAMPLE
    .\Check-Updates.ps1
    .\Check-Updates.ps1 -ReportPath "C:\Temp\report.json" -IncludeDrivers

.NOTES
    Must be run as Administrator.
    Requires Windows 10 / Server 2016 or later.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ReportPath = "$env:ProgramData\VulFixes\UpdateReport.json",
    [switch]$IncludeDrivers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: Write a coloured section header
# ---------------------------------------------------------------------------
function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Windows Update
# ---------------------------------------------------------------------------
function Get-WindowsUpdates {
    Write-Section 'Windows Update'

    $updates = @()

    try {
        $session   = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher  = $session.CreateUpdateSearcher()
        $result    = $searcher.Search('IsInstalled=0 and Type=''Software'' and IsHidden=0')

        foreach ($update in $result.Updates) {
            $updates += [PSCustomObject]@{
                Source      = 'WindowsUpdate'
                Name        = $update.Title
                KB          = ($update.KBArticleIDs -join ', ')
                Severity    = $update.MsrcSeverity
                Size        = [math]::Round($update.MaxDownloadSize / 1MB, 2)
                RebootRequired = $update.InstallationBehavior.RebootBehavior -ne 0
            }
            Write-Host ("  [{0}] {1}" -f ($update.MsrcSeverity ?? 'Unrated'), $update.Title)
        }
    }
    catch {
        Write-Warning "Could not query Windows Update: $_"
    }

    if ($updates.Count -eq 0) {
        Write-Host '  No Windows updates found.' -ForegroundColor Green
    }

    return $updates
}

# ---------------------------------------------------------------------------
# 2. Installed applications via winget
# ---------------------------------------------------------------------------
function Get-WingetUpdates {
    Write-Section 'Winget package updates'

    $updates = @()

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warning 'winget not found. Skipping application update check.'
        return $updates
    }

    try {
        # Run winget upgrade and parse the tabular output
        $raw = & winget upgrade --accept-source-agreements 2>&1

        # Skip header lines; each data row has at least 4 tab/space-separated columns
        $inTable = $false
        foreach ($line in $raw) {
            if ($line -match '^-{3,}') { $inTable = $true; continue }
            if (-not $inTable) { continue }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # winget uses variable-width columns separated by two or more spaces
            $cols = $line -split '\s{2,}' | Where-Object { $_ -ne '' }
            if ($cols.Count -ge 4) {
                $updates += [PSCustomObject]@{
                    Source          = 'Winget'
                    Name            = $cols[0].Trim()
                    Id              = $cols[1].Trim()
                    CurrentVersion  = $cols[2].Trim()
                    AvailableVersion = $cols[3].Trim()
                    RebootRequired  = $false
                }
                Write-Host ("  {0}  {1} -> {2}" -f $cols[0].Trim(), $cols[2].Trim(), $cols[3].Trim())
            }
        }
    }
    catch {
        Write-Warning "winget upgrade check failed: $_"
    }

    if ($updates.Count -eq 0) {
        Write-Host '  No winget updates found.' -ForegroundColor Green
    }

    return $updates
}

# ---------------------------------------------------------------------------
# 3. Driver updates (via Windows Update COM, software type = Driver)
# ---------------------------------------------------------------------------
function Get-DriverUpdates {
    Write-Section 'Driver updates'

    $updates = @()

    try {
        $session  = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search('IsInstalled=0 and Type=''Driver'' and IsHidden=0')

        foreach ($update in $result.Updates) {
            $updates += [PSCustomObject]@{
                Source         = 'DriverUpdate'
                Name           = $update.Title
                DriverClass    = ($update.DriverClass ?? 'Unknown')
                RebootRequired = $update.InstallationBehavior.RebootBehavior -ne 0
            }
            Write-Host ("  {0}" -f $update.Title)
        }
    }
    catch {
        Write-Warning "Could not query driver updates: $_"
    }

    if ($updates.Count -eq 0) {
        Write-Host '  No driver updates found.' -ForegroundColor Green
    }

    return $updates
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$report = [ordered]@{
    GeneratedAt    = (Get-Date -Format 'o')
    ComputerName   = $env:COMPUTERNAME
    WindowsUpdates = @()
    WingetUpdates  = @()
    DriverUpdates  = @()
}

$report.WindowsUpdates = Get-WindowsUpdates

$report.WingetUpdates  = Get-WingetUpdates

if ($IncludeDrivers) {
    $report.DriverUpdates = Get-DriverUpdates
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Section 'Summary'
$totalUpdates = $report.WindowsUpdates.Count + $report.WingetUpdates.Count + $report.DriverUpdates.Count
Write-Host ("  Windows Updates : {0}" -f $report.WindowsUpdates.Count)
Write-Host ("  Winget Updates  : {0}" -f $report.WingetUpdates.Count)
Write-Host ("  Driver Updates  : {0}" -f $report.DriverUpdates.Count)
Write-Host ("  TOTAL           : {0}" -f $totalUpdates) -ForegroundColor Yellow

$rebootNeeded = ($report.WindowsUpdates + $report.DriverUpdates | Where-Object { $_.RebootRequired }) -ne $null
if ($rebootNeeded) {
    Write-Host '  One or more updates will require a reboot.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Save report
# ---------------------------------------------------------------------------
$reportDir = Split-Path $ReportPath -Parent
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host "`nReport saved to: $ReportPath" -ForegroundColor Green
