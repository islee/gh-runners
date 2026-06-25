<#
.SYNOPSIS
    Ephemeral relaunch loop for a vanilla actions/runner on Windows.

.DESCRIPTION
    Driven by a Windows Scheduled Task (gh-runner-windows@<n>). Loops forever:
      1. Read config.env from the script's own instance dir.
      2. Acquire a fresh registration token each cycle (ephemeral runners consume it after one job).
      3. Register (--ephemeral) and run exactly one job (run.cmd exits after it).
      4. Re-register clean. Repeat.

    Token priority (checked in order): RUNNER_TOKEN (static) -> BROKER_URL (broker) -> ACCESS_TOKEN (PAT).
    config.env (ACL-restricted, written by install.ps1) lives in this script's dir and supplies the values.

    Graceful shutdown: a finally block makes a BEST-EFFORT deregister when the loop exits normally or
    on a soft stop. A hard task kill (Stop-ScheduledTask force-terminating the process) may skip it, so
    it is NOT authoritative — uninstall.ps1 performs the reliable removal (mint remove-token +
    config.cmd remove). Worst case a stale "offline" entry lingers until GitHub prunes it or the next
    --replace cycle reclaims the name.

    NOTE: All logs go to the host's Application event log (source gh-runner) AND to the runner's own
    _diag\ directory (written by run.cmd). To follow logs:
      Get-WinEvent -LogName Application -MaxEvents 50 | Where-Object Source -eq 'gh-runner'
      Or: tail the _diag\Runner_*.log files in each instance dir.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CRITICAL: PowerShell 5.1 negotiates TLS 1.0 by default; the broker (Render) and api.github.com both
# require TLS 1.2+. Force it before any Invoke-RestMethod call, or token fetches fail at the handshake.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ── Bootstrap — config.env sits next to this script (its instance runner dir) ─
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigEnv = Join-Path $ScriptDir 'config.env'
if (-not (Test-Path $ConfigEnv)) {
    Write-Error "[ERROR] config.env not found at $ConfigEnv. Run install.ps1 first."
    exit 1
}

# Parse config.env: KEY="value" lines (shell-style, written by install.ps1). Skip comments/blanks.
$config = @{}
foreach ($line in (Get-Content $ConfigEnv)) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -match '^([A-Z_]+)="?(.*?)"?$') {
        $config[$Matches[1]] = $Matches[2]
    }
}

# ── Resolve config values ──────────────────────────────────────────────────────
$GhOrg        = if ($config['GH_ORG'])        { $config['GH_ORG'] }        else { 'your-org' }
$RunnerLabels = if ($config['RUNNER_LABELS'])  { $config['RUNNER_LABELS'] } else { 'self-hosted,windows,x64,light' }
# Display name: install.ps1 writes the gh-runner-<type>-<id>-<n> name into config.env. If absent
# (hand-rolled config), fall back to hostname + a short random suffix.
$RunnerName   = if ($config['RUNNER_NAME'])    { $config['RUNNER_NAME'] }   else { "$env:COMPUTERNAME-$(New-Guid | Select-Object -ExpandProperty Guid | ForEach-Object { $_.Replace('-','').Substring(0,8) })" }
$RunnerToken  = if ($config['RUNNER_TOKEN'])   { $config['RUNNER_TOKEN'] }  else { '' }
$BrokerUrl    = if ($config['BROKER_URL'])     { $config['BROKER_URL'] }    else { '' }
$BrokerSecret = if ($config['BROKER_SECRET'])  { $config['BROKER_SECRET'] } else { '' }
$AccessToken  = if ($config['ACCESS_TOKEN'])   { $config['ACCESS_TOKEN'] }  else { '' }

$RegistrationRetrySeconds = 30

# ── Logging — write to Application event log + stderr ─────────────────────────
# WHY: the scheduled task has no attached console; event log is the standard Windows mechanism.
# Fallback Write-Host still surfaces when run interactively.
function Ensure-EventSource {
    if (-not [Diagnostics.EventLog]::SourceExists('gh-runner')) {
        try { [Diagnostics.EventLog]::CreateEventSource('gh-runner', 'Application') }
        catch { <# Ignore — requires elevation; logs still go to stderr #> }
    }
}
Ensure-EventSource

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts  = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $out = "[$ts] [$Level]  $Msg"
    Write-Host $out
    try {
        $entryType = if ($Level -eq 'WARN') { 'Warning' } elseif ($Level -eq 'ERROR') { 'Error' } else { 'Information' }
        Write-EventLog -LogName Application -Source 'gh-runner' -EventId 1 -EntryType $entryType -Message $Msg -ErrorAction SilentlyContinue
    } catch { <# Non-fatal: log to console only if event log is unavailable #> }
}
function Log   { param([string]$Msg) Write-Log 'INFO'  $Msg }
function Warn  { param([string]$Msg) Write-Log 'WARN'  $Msg }
function Fatal { param([string]$Msg) Write-Log 'ERROR' $Msg; exit 1 }

# Mask credentials embedded in a URL authority (https://user:secret@host -> https://***@host).
function Mask-Url { param([string]$Url) $Url -replace '://[^@/]+@', '://***@' }

# ── Graceful shutdown — deregister before exit ─────────────────────────────────
# WHY: PowerShell scheduled tasks receive a termination request (CTRL_BREAK_EVENT or process kill)
# when Stop-ScheduledTask or a system shutdown fires. Register-ObjectEvent on the process exit is
# unreliable for task termination; a try/finally wrapping the main loop is the most reliable hook.
$script:CurrentRegToken = ''

function Invoke-Deregister {
    Log "Deregister: attempting best-effort runner removal."
    $removeTok = ''
    try {
        if ($BrokerUrl -ne '') {
            $resp = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "$($BrokerUrl.TrimEnd('/'))/remove-token" `
                -Headers @{ Authorization = "Bearer $BrokerSecret"; 'X-Runner-Name' = $RunnerName }
            $removeTok = $resp.token
        } elseif ($AccessToken -ne '') {
            $resp = Invoke-RestMethod -Method Post -TimeoutSec 10 `
                -Uri "https://api.github.com/orgs/$GhOrg/actions/runners/remove-token" `
                -Headers @{
                    Authorization          = "Bearer $AccessToken"
                    Accept                 = 'application/vnd.github+json'
                    'X-GitHub-Api-Version' = '2022-11-28'
                }
            $removeTok = $resp.token
        }
    } catch {
        Warn "Could not fetch remove-token: $_"
    }
    if ($removeTok -eq '') { $removeTok = $script:CurrentRegToken }
    if ($removeTok -ne '' -and (Test-Path (Join-Path $ScriptDir 'config.cmd'))) {
        try {
            & (Join-Path $ScriptDir 'config.cmd') remove --token $removeTok 2>&1 | Out-Null
            Log "Runner deregistered."
        } catch {
            Warn "config.cmd remove failed (token may be expired): $_"
        }
    } else {
        Warn "No remove-token available; runner may linger in org settings."
    }
    # CRITICAL: clear the token from memory immediately after use.
    $removeTok = ''
    $script:CurrentRegToken = ''
}

# ── Token acquisition — returns the token string; throws on retryable failure ──
function Get-RegToken {
    # Priority 1: static RUNNER_TOKEN (model A). WARNING: expires ~1h after minting, so it survives
    # only the FIRST cycle of this re-registering loop. Unattended -> use B or PAT.
    if ($RunnerToken -ne '') {
        Log "Using static RUNNER_TOKEN (one-off; expires ~1h — see README on sustainable creds)."
        return $RunnerToken
    }

    # Priority 2: token-broker (model B). No GitHub credential lives on this host.
    if ($BrokerUrl -ne '') {
        Log "Fetching registration token from broker: $(Mask-Url $BrokerUrl)"
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 15 `
            -Uri "$($BrokerUrl.TrimEnd('/'))/token" `
            -Headers @{ Authorization = "Bearer $BrokerSecret"; 'X-Runner-Name' = $RunnerName }
        if (-not $resp.token) { throw "Broker returned an empty token." }
        return $resp.token
    }

    # Priority 3: mint from ACCESS_TOKEN — a fine-grained PAT scoped to organization_self_hosted_runners.
    # NOT an org-admin PAT.
    if ($AccessToken -ne '') {
        Log "Minting registration token via GitHub REST API."
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 10 `
            -Uri "https://api.github.com/orgs/$GhOrg/actions/runners/registration-token" `
            -Headers @{
                Authorization          = "Bearer $AccessToken"
                Accept                 = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
        if (-not $resp.token) { throw "GitHub REST API returned an empty token." }
        return $resp.token
    }

    throw "No credential available (RUNNER_TOKEN, BROKER_URL, ACCESS_TOKEN all unset). Fix config.env."
}

# ── Main loop ──────────────────────────────────────────────────────────────────
Set-Location $ScriptDir
Log "gh-runner loop starting. Org=$GhOrg, Name=$RunnerName, Labels=$RunnerLabels"

$retryAttempt = 0

try {
    while ($true) {
        Log "Acquiring registration token..."
        $regTok = $null
        try {
            $regTok = Get-RegToken
        } catch {
            $retryAttempt++
            # Exponential backoff capped at 300s with jitter to decorrelate hosts hitting GitHub
            # rate-limits simultaneously (thundering herd mitigation).
            $exp     = [Math]::Min($retryAttempt - 1, 6)
            $backoff = [Math]::Min($RegistrationRetrySeconds * [Math]::Pow(2, $exp), 300)
            $backoff = [int]$backoff + (Get-Random -Minimum 0 -Maximum 15)
            Warn "Token acquisition failed (attempt $retryAttempt): $_ — retrying in ${backoff}s."
            Start-Sleep -Seconds $backoff
            continue
        }
        $retryAttempt = 0
        $script:CurrentRegToken = $regTok

        # Fixed per-instance name (gh-runner-<type>-<id>-<n> from config.env). --replace re-claims
        # this instance's own prior registration each ephemeral cycle.
        Log "Registering runner: $RunnerName"

        # --ephemeral: deregister after exactly one job. --replace: clear a stale same-name registration.
        $configArgs = @(
            '--unattended', '--ephemeral', '--replace', '--disableupdate',
            '--url',    "https://github.com/$GhOrg",
            '--token',  $regTok,
            '--labels', $RunnerLabels,
            '--name',   $RunnerName
        )
        $configResult = & (Join-Path $ScriptDir 'config.cmd') @configArgs
        if ($LASTEXITCODE -ne 0) {
            Warn "config.cmd failed (exit $LASTEXITCODE) — will retry in ${RegistrationRetrySeconds}s."
            $script:CurrentRegToken = ''
            # CRITICAL: clear token from memory before sleeping; config.cmd did not consume it.
            $regTok = ''
            # WHY: config.cmd fails with "already configured" when stale local registration files
            # (.runner, .credentials, .credentials_rsaparams) remain from a prior cycle or reinstall.
            # Clearing them self-heals the loop. A prior registration may linger OFFLINE in GitHub
            # until pruned or the next --replace cycle reclaims the name.
            foreach ($regFile in @('.runner', '.credentials', '.credentials_rsaparams')) {
                Remove-Item -Path (Join-Path $ScriptDir $regFile) -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds $RegistrationRetrySeconds
            continue
        }
        # CRITICAL: clear the registration token from memory — config.cmd has consumed it.
        $regTok = ''
        $script:CurrentRegToken = ''

        Log "Runner registered as $RunnerName. Waiting for a job..."
        # run.cmd blocks until exactly one job completes (--ephemeral), then exits. Loop regardless so
        # the runner re-registers rather than staying stuck on a job error.
        & (Join-Path $ScriptDir 'run.cmd')
        if ($LASTEXITCODE -ne 0) {
            Warn "run.cmd exited with code $LASTEXITCODE — looping to re-register."
        } else {
            Log "Job complete. Re-registering for next job."
        }
    }
} finally {
    # Best-effort deregister on a clean/soft exit. A hard task kill may skip this finally entirely —
    # uninstall.ps1 is the authoritative removal path. See the .DESCRIPTION note.
    Log "Loop exiting — best-effort deregister."
    Invoke-Deregister
}
