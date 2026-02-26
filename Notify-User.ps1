<#
.SYNOPSIS
    Displays a pop-up notification to every interactive user currently logged
    into the local Windows machine.

.DESCRIPTION
    The script iterates over all active console/RDP sessions reported by
    quser.exe and sends each user a Windows MessageBox via a short PowerShell
    job executed under that user's session.  This ensures the message appears
    on the user's desktop regardless of whether they are on the console or a
    Remote Desktop session.

    When running on a Server SKU the script falls back to msg.exe if the
    user-session job approach is unavailable.

.PARAMETER Message
    The body text of the pop-up notification.

.PARAMETER Title
    The title bar text of the pop-up dialog.
    Defaults to "IT Notification".

.PARAMETER TimeoutSeconds
    Number of seconds before the pop-up automatically dismisses itself.
    0 means the dialog stays open until the user closes it (default).

.EXAMPLE
    .\Notify-User.ps1 -Message "Please restart your computer to finish installing updates." `
                      -Title "Restart Required"

    .\Notify-User.ps1 -Message "A reboot will be forced in 15 minutes." `
                      -Title "Forced Reboot Warning" -TimeoutSeconds 900

.NOTES
    Must be run as Administrator (required to query and message user sessions).
    Requires Windows Vista / Server 2008 or later.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Message,

    [string]$Title = 'IT Notification',

    [ValidateRange(0, 86400)]
    [int]$TimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # Don't abort on non-critical errors

# ---------------------------------------------------------------------------
# Helper: Parse quser output into session objects
# ---------------------------------------------------------------------------
function Get-ActiveUserSessions {
    $sessions = @()

    try {
        # quser output varies by locale/version; use regex to be robust
        $raw = & quser 2>&1
        foreach ($line in $raw) {
            # Match lines like:  username   sessionname  id  state  idle  logon
            if ($line -match '^\s*(?<user>\S+)\s+(?<session>\S+)\s+(?<id>\d+)\s+(?<state>Active|Disc)') {
                $sessions += [PSCustomObject]@{
                    UserName    = $Matches['user']
                    SessionName = $Matches['session']
                    SessionId   = [int]$Matches['id']
                    State       = $Matches['state']
                }
            }
        }
    }
    catch {
        Write-Warning "quser failed: $_"
    }

    return $sessions
}

# ---------------------------------------------------------------------------
# Helper: Send a message to a specific session using msg.exe
# ---------------------------------------------------------------------------
function Send-MsgExe {
    param(
        [int]$SessionId,
        [string]$Text,
        [int]$Timeout
    )

    $args = @("$SessionId")
    if ($Timeout -gt 0) { $args += '/time:' + $Timeout }
    $args += $Text

    try {
        & msg @args 2>&1 | Out-Null
        Write-Host "  [msg.exe] Sent to session $SessionId"
    }
    catch {
        Write-Warning "  [msg.exe] Failed for session ${SessionId}: $_"
    }
}

# ---------------------------------------------------------------------------
# Helper: Inject a MessageBox into a user session via a scheduled task
#         (works when msg.exe is blocked or unavailable)
# ---------------------------------------------------------------------------
function Send-MessageBoxToSession {
    param(
        [string]$UserName,
        [int]$SessionId,
        [string]$MsgText,
        [string]$MsgTitle,
        [int]$Timeout
    )

    # Escape single quotes in the message/title for embedding in a script block
    $safeMsg   = $MsgText  -replace "'", "''"
    $safeTitle = $MsgTitle -replace "'", "''"

    $timeoutLine = if ($Timeout -gt 0) {
        # WScript.Shell.Popup has a built-in timeout parameter
        "`$wsh = New-Object -ComObject WScript.Shell; `$wsh.Popup('$safeMsg', $Timeout, '$safeTitle', 0x30) | Out-Null"
    }
    else {
        "[System.Windows.Forms.MessageBox]::Show('$safeMsg','$safeTitle',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null"
    }

    $scriptBlock = @"
Add-Type -AssemblyName System.Windows.Forms
$timeoutLine
"@

    $encodedCmd = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($scriptBlock)
    )

    # Create a one-time scheduled task that runs in the user's interactive session
    $taskName = "VulFixes_Notify_$(Get-Date -Format 'yyyyMMddHHmmss')_$SessionId"

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCmd"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive `
                     -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Trigger $trigger -Principal $principal -Force | Out-Null

        Start-ScheduledTask -TaskName $taskName
        Write-Host ("  [ScheduledTask] Notification dispatched to user '{0}' (session {1})" `
            -f $UserName, $SessionId) -ForegroundColor Green

        # Give the task a moment to start then clean up
        Start-Sleep -Seconds 10
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning ("  [ScheduledTask] Could not notify '{0}': {1}" -f $UserName, $_)
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "`n=== Notify-User.ps1 ===" -ForegroundColor Cyan
Write-Host "Title   : $Title"
Write-Host "Message : $Message"
if ($TimeoutSeconds -gt 0) { Write-Host "Timeout : ${TimeoutSeconds}s" }

$sessions = Get-ActiveUserSessions

if ($sessions.Count -eq 0) {
    Write-Host 'No active user sessions found.' -ForegroundColor Yellow
    exit 0
}

Write-Host ("`nFound {0} active session(s):" -f $sessions.Count)
$sessions | Format-Table UserName, SessionName, SessionId, State -AutoSize

foreach ($session in $sessions) {
    Write-Host ("`nNotifying user '{0}' on session {1}..." -f $session.UserName, $session.SessionId)

    # Prefer the scheduled-task method (works over RDP and on modern Windows)
    # Fall back to msg.exe if the scheduled task approach fails
    try {
        Send-MessageBoxToSession -UserName    $session.UserName `
                                  -SessionId   $session.SessionId `
                                  -MsgText     $Message `
                                  -MsgTitle    $Title `
                                  -Timeout     $TimeoutSeconds
    }
    catch {
        Write-Warning "MessageBox method failed; falling back to msg.exe: $_"
        Send-MsgExe -SessionId $session.SessionId -Text $Message -Timeout $TimeoutSeconds
    }
}

Write-Host "`nNotification complete." -ForegroundColor Green
