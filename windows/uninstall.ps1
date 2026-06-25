#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remove the "windows" scheduled-task runners installed by install.ps1.

.DESCRIPTION
    For each gh-runner-windows@<i>: stop the scheduled task, then deregister the runner DIRECTLY from
    GitHub (mint a remove-token from the broker or PAT in config.env and run config.cmd remove), then
    unregister the task. The direct removal is authoritative — it does not rely on runner-loop.ps1's
    best-effort finally block, which a hard task termination may skip. Optionally removes the runner
    dirs. A runner still showing in org -> Settings -> Actions -> Runners after this was likely mid-job
    or used a static token (no remove-token) — remove those manually.

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

# PowerShell 5.1 defaults to TLS 1.0; the broker (Render) + api.github.com require 1.2+ for the
# remove-token call below.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" }
function Write-Warn { param([string]$Msg) Write-Warning "[WARN]  $Msg" }

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[ERROR] Run this script elevated (as Administrator)."; exit 1
}

# Authoritatively deregister an instance's runner from GitHub: parse its config.env (admin-readable),
# mint a remove-token (broker or PAT), and run config.cmd remove. Best-effort — never throws.
function Invoke-DirectDeregister {
    param([string]$InstDir)
    $cfgFile = Join-Path $InstDir 'config.env'
    $cmd     = Join-Path $InstDir 'config.cmd'
    if (-not (Test-Path $cfgFile) -or -not (Test-Path $cmd)) {
        Write-Warn "No config.env/config.cmd in $InstDir — skipping direct deregister."
        return
    }
    $cfg = @{}
    foreach ($l in (Get-Content $cfgFile)) {
        $l = $l.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        if ($l -match '^([A-Z_]+)="?(.*?)"?$') { $cfg[$Matches[1]] = $Matches[2] }
    }
    $removeTok = ''
    try {
        if ($cfg.ContainsKey('BROKER_URL') -and $cfg['BROKER_URL'] -ne '') {
            $resp = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "$($cfg['BROKER_URL'].TrimEnd('/'))/remove-token" `
                -Headers @{ Authorization = "Bearer $($cfg['BROKER_SECRET'])"; 'X-Runner-Name' = $cfg['RUNNER_NAME'] }
            $removeTok = $resp.token
        } elseif ($cfg.ContainsKey('ACCESS_TOKEN') -and $cfg['ACCESS_TOKEN'] -ne '') {
            $resp = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "https://api.github.com/orgs/$($cfg['GH_ORG'])/actions/runners/remove-token" `
                -Headers @{
                    Authorization          = "Bearer $($cfg['ACCESS_TOKEN'])"
                    Accept                 = 'application/vnd.github+json'
                    'X-GitHub-Api-Version' = '2022-11-28'
                }
            $removeTok = $resp.token
        }
    } catch {
        Write-Warn "remove-token fetch failed for $InstDir: $_"
    }
    if ($removeTok -ne '') {
        try {
            & $cmd remove --token $removeTok 2>&1 | Out-Null
            Write-Info "Deregistered runner in $InstDir."
        } catch {
            Write-Warn "config.cmd remove failed in $InstDir (token may be expired): $_"
        }
        $removeTok = ''
    } else {
        Write-Warn "No remove-token for $InstDir (static token, or fetch failed) — may need manual removal."
    }
}

for ($i = 1; $i -le $Count; $i++) {
    $TaskName = "gh-runner-windows@$i"
    $InstDir = Join-Path $RunnerBase $i
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Info "Stopping scheduled task $TaskName..."
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3   # let run.cmd settle before we touch the runner config
            # Authoritative removal — does not depend on the loop's finally hook firing.
            Invoke-DirectDeregister -InstDir $InstDir
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Info "Removed scheduled task $TaskName."
        } catch {
            Write-Warn "Could not fully remove $TaskName: $_"
        }
    } else {
        Write-Warn "Scheduled task $TaskName not found (already removed or never installed)."
        # Still attempt a direct deregister in case the task was manually deleted but the runner lingers.
        Invoke-DirectDeregister -InstDir $InstDir
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
