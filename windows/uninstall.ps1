#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the "windows" scheduled-task runners installed by install.ps1.

.DESCRIPTION
    Stops and unregisters each gh-runner-windows@<i> scheduled task (which triggers a SIGTERM-equivalent,
    allowing runner-loop.ps1's finally block to deregister the runner from GitHub). Optionally removes
    the runner dirs. Any runner still showing in org -> Settings -> Actions -> Runners after this
    script was either mid-job or had an expired deregister token — remove those manually.

    Run elevated (as Administrator). Usage:
        .\uninstall.ps1 [-Count N] [-RunnerBase DIR] [-Purge]

.PARAMETER Count
    Number of instances to remove (must match what install.ps1 created). Default: 1.

.PARAMETER RunnerBase
    Parent directory used by install.ps1. Instance i was at <RunnerBase>\<i>. Default: C:\actions-runner-windows.

.PARAMETER Purge
    When set, delete the runner dirs under -RunnerBase after stopping the tasks. Default: false (keep dirs).

.EXAMPLE
    .\uninstall.ps1 -Count 2 -RunnerBase C:\actions-runner-windows
    .\uninstall.ps1 -Count 2 -RunnerBase C:\actions-runner-windows -Purge
#>

[CmdletBinding()]
param(
    [int]   $Count       = 1,
    [string]$RunnerBase  = 'C:\actions-runner-windows',
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" }
function Write-Warn { param([string]$Msg) Write-Warning "[WARN]  $Msg" }

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[ERROR] Run this script elevated (as Administrator)."; exit 1
}

for ($i = 1; $i -le $Count; $i++) {
    $TaskName = "gh-runner-windows@$i"
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Info "Stopping scheduled task $TaskName (runner-loop.ps1 finally block will deregister)..."
        try {
            Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
            # Give runner-loop.ps1's finally block a moment to attempt deregistration.
            Start-Sleep -Seconds 5
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Info "Removed scheduled task $TaskName."
        } catch {
            Write-Warn "Could not fully remove $TaskName: $_"
        }
    } else {
        Write-Warn "Scheduled task $TaskName not found (already removed or never installed)."
    }
}

if (Test-Path $RunnerBase) {
    if ($Purge) {
        Write-Info "Purging runner dirs under $RunnerBase..."
        Remove-Item -Path $RunnerBase -Recurse -Force
        Write-Info "Removed $RunnerBase."
    } else {
        Write-Info "Runner dirs kept at $RunnerBase (pass -Purge to delete)."
    }
} else {
    Write-Info "$RunnerBase does not exist — nothing to purge."
}

Write-Host ''
Write-Host "windows runners uninstalled. If any still show in org -> Settings -> Actions -> Runners,"
Write-Host "remove them manually (they were likely mid-job or had an expired deregister token)."
