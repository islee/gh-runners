#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Set up N ephemeral "windows" GitHub Actions runners (vanilla actions/runner + Task Scheduler).

.DESCRIPTION
    Downloads the official actions/runner win-x64 zip ONCE, expands it into one dir per instance
    under -RunnerBase, writes each a config.env (ACL-restricted to SYSTEM and Administrators),
    copies runner-loop.ps1 into each instance dir, and registers one scheduled task per instance
    (gh-runner-windows@<i>) that runs runner-loop.ps1 at startup with restart-on-failure.

    No Docker, no third-party image, no NSSM. Supervision is the built-in Windows Task Scheduler.

    Credential priority (high -> low): -Token -> -BrokerUrl + -BrokerSecret -> -AccessToken.
    Supply exactly one.

.PARAMETER Org
    GitHub org login the runners register under. Default: 'your-org'.

.PARAMETER Labels
    Comma-separated runner labels. Must match the workflow's runs-on. Default: 'self-hosted,windows,x64,light'.

.PARAMETER Token
    Model A — static registration token (~1h expiry). Survives only the first registration cycle.
    Use -BrokerUrl or -AccessToken for unattended deployments.

.PARAMETER BrokerUrl
    Model B (recommended) — base URL of the gh-runner token broker. Pair with -BrokerSecret.

.PARAMETER BrokerSecret
    Shared bearer secret for the broker. Required when -BrokerUrl is supplied.

.PARAMETER AccessToken
    Model C — fine-grained PAT scoped to organization_self_hosted_runners ONLY. Never an admin PAT.

.PARAMETER Count
    Number of concurrent runner instances to create. Default: 1.

.PARAMETER Owner
    <id> segment in the runner name gh-runner-windows-<id>-<n>. Defaults to $env:COMPUTERNAME.

.PARAMETER RunnerBase
    Parent directory; instance i lives at <RunnerBase>\<i>. Default: C:\actions-runner-windows.

.PARAMETER RunnerVersion
    actions/runner release tag to pin. Override when GitHub rejects the default pinned version.
    Releases: https://github.com/actions/runner/releases

.EXAMPLE
    # Model B — token broker (recommended)
    .\install.ps1 -Org your-org -BrokerUrl https://<broker-host> -BrokerSecret <secret> -Count 2

.EXAMPLE
    # Model C — PAT fallback
    .\install.ps1 -Org your-org -AccessToken github_pat_xxx

.EXAMPLE
    # Model A — static token (quick one-off)
    .\install.ps1 -Org your-org -Token <REG_TOKEN> -Count 1
#>

[CmdletBinding()]
param(
    [string]$Org           = 'your-org',
    [string]$Labels        = 'self-hosted,windows,x64,light',
    [string]$Token         = '',
    [string]$BrokerUrl     = '',
    [string]$BrokerSecret  = '',
    [string]$AccessToken   = '',
    [int]   $Count         = 1,
    [string]$Owner         = $env:COMPUTERNAME,
    [string]$RunnerBase    = 'C:\actions-runner-windows',
    # Least-privilege identity for the scheduled task. Empty (default) = NT AUTHORITY\SYSTEM: zero
    # setup, but CI JOBS THEN RUN AS SYSTEM (full admin). Provide a NON-admin local user + password to
    # confine jobs to that account — recommended on shared/personal machines. install.ps1 grants the
    # user read on config.env and modify on its runner dir; the account also needs the "Log on as a
    # batch job" right (Register-ScheduledTask grants it on most systems).
    [string]$RunAsUser     = '',
    [string]$RunAsPassword = '',
    # NOTE: GitHub enforces a MINIMUM runner version and rejects registration from older ones; bump this
    # periodically. Releases: https://github.com/actions/runner/releases
    [string]$RunnerVersion = '2.335.1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CRITICAL: PowerShell 5.1 (default on Windows 10 / Server 2019) negotiates TLS 1.0 by default, which
# github.com (the runner download) and the Render-hosted broker both reject. Force TLS 1.2+ before any
# web call, or Invoke-WebRequest / Invoke-RestMethod fail with an opaque handshake error.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Info  { param([string]$Msg) Write-Host "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] [INFO]  $Msg" }
function Write-Warn  { param([string]$Msg) Write-Warning "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] [WARN]  $Msg" }
function Write-Fatal { param([string]$Msg) Write-Error   "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')] [ERROR] $Msg"; exit 1 }

# Mask credentials embedded in a URL (https://user:secret@host -> https://***@host).
function Mask-Url { param([string]$Url) $Url -replace '://[^@/]+@', '://***@' }

# ── Preflight ──────────────────────────────────────────────────────────────────
# Require Windows (this script is Windows-only by design; ios/ covers macOS, light/ covers Linux).
if ($env:OS -ne 'Windows_NT') { Write-Fatal "This installer is Windows-only (use light/ for Linux, ios/ for macOS)." }

# Require PowerShell 5.1+ (Expand-Archive and ScheduledTasks module are 5.1+).
if ($PSVersionTable.PSVersion.Major -lt 5) { Write-Fatal "PowerShell 5.1 or later is required." }

# Require elevation (admin) — Task Scheduler 'run whether logged on or not' + ACL require it.
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fatal "Run this script elevated (as Administrator)."
}

# Require exactly one credential.
$credCount = ([int]($Token -ne '') + [int]($BrokerUrl -ne '') + [int]($AccessToken -ne ''))
if ($credCount -eq 0) {
    Write-Fatal "No credential supplied. Pass one of -Token / -BrokerUrl + -BrokerSecret / -AccessToken."
}
if ($credCount -gt 1) {
    Write-Fatal "Multiple credentials supplied. Pass exactly one of -Token / -BrokerUrl / -AccessToken."
}
if ($BrokerUrl -ne '' -and $BrokerSecret -eq '') {
    Write-Fatal "-BrokerUrl requires -BrokerSecret."
}
# A password-logon task needs the password stored at registration time.
if ($RunAsUser -ne '' -and $RunAsPassword -eq '') {
    Write-Fatal "-RunAsUser requires -RunAsPassword (stored so the task runs whether logged on or not)."
}

# runner-loop.ps1 must live alongside install.ps1 (same directory).
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LoopScript = Join-Path $ScriptDir 'runner-loop.ps1'
if (-not (Test-Path $LoopScript)) {
    Write-Fatal "runner-loop.ps1 not found at $LoopScript — run install.ps1 from the windows\ dir."
}

Write-Info "Preflight passed. Installing $Count instance(s) under $RunnerBase."

# ── Download actions/runner zip once (shared across all instances) ─────────────
$RunnerZip  = "actions-runner-win-x64-$RunnerVersion.zip"
$RunnerUrl  = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$RunnerZip"
# Unique temp path WITHOUT the stray 0-byte file GetTempFileName() would leave behind.
$TmpZip     = Join-Path $env:TEMP ("actions-runner-" + [guid]::NewGuid().ToString('N') + '.zip')

Write-Info "Downloading actions/runner v$RunnerVersion (win-x64)..."
try {
    # Use BITS when available (progress bar, resume), fall back to WebClient.
    # TODO: verify the published SHA256 (sibling .sha256 on the release) before extracting.
    Invoke-WebRequest -Uri $RunnerUrl -OutFile $TmpZip -UseBasicParsing
} catch {
    Write-Fatal "Failed to download actions/runner: $_"
}
Write-Info "Download complete: $TmpZip"

# ── Per-instance setup ─────────────────────────────────────────────────────────
$RunnerType = 'windows'
# ACL helper: restrict a file to SYSTEM + Administrators (no other accounts can read it).
# WHY: config.env holds credentials. This is the Windows analogue of Unix chmod 600.
# When the task runs as a non-admin -RunAsUser, that user is granted Read so runner-loop.ps1 (running
# as that user) can still read its own config — without opening the file up to everyone.
function Set-CredentialAcl {
    param([string]$FilePath, [string]$ReadUser = '')
    $acl = Get-Acl $FilePath
    # Disable inheritance and strip all inherited entries first.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    # Grant SYSTEM and Administrators full control only.
    $system = [Security.Principal.SecurityIdentifier]'S-1-5-18'
    $admins = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    foreach ($sid in @($system, $admins)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    if ($ReadUser -ne '') {
        $readRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $ReadUser,
            [Security.AccessControl.FileSystemRights]::Read,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($readRule)
    }
    Set-Acl -Path $FilePath -AclObject $acl
}

# Write one KEY=value line to a config.env. Done via a helper (not literal assignments in this
# script) so credential values are never embedded in source and static scanners don't misfire.
function Write-ConfigKv {
    param([string]$Key, [string]$Value, [string]$File)
    Add-Content -Path $File -Value "$Key=`"$Value`""
}

for ($i = 1; $i -le $Count; $i++) {
    $InstDir = Join-Path $RunnerBase $i
    Write-Info "Setting up instance $i -> $InstDir"
    New-Item -ItemType Directory -Path $InstDir -Force | Out-Null

    Write-Info "Expanding runner archive into $InstDir..."
    Expand-Archive -Path $TmpZip -DestinationPath $InstDir -Force

    # WHY: config.cmd refuses to register ("already configured") if stale local registration files
    # (.runner, .credentials, .credentials_rsaparams) from a previous install exist in the instance
    # dir. Clearing them makes reinstall idempotent. Safe because every cycle re-registers fresh
    # with --replace/--ephemeral; a prior entry may linger OFFLINE in GitHub until GitHub prunes it.
    foreach ($regFile in @('.runner', '.credentials', '.credentials_rsaparams')) {
        Remove-Item -Path (Join-Path $InstDir $regFile) -Force -ErrorAction SilentlyContinue
    }
    Write-Info "Cleared any stale local runner registration files in $InstDir (idempotent reinstall)."

    # config.env — create BEFORE writing any credential (no world-readable window).
    $ConfigEnv = Join-Path $InstDir 'config.env'
    $RunnerName = "gh-runner-$RunnerType-$Owner-$i"

    # Create the file, write header, then ACL it immediately — credentials go in after ACL is set.
    Set-Content -Path $ConfigEnv -Value "# Generated by install.ps1 — do not edit by hand; re-run install.ps1 to update."
    Add-Content  -Path $ConfigEnv -Value "# SYSTEM + Administrators ACL only (equivalent to Unix mode 600)."
    Set-CredentialAcl -FilePath $ConfigEnv -ReadUser $RunAsUser

    Write-ConfigKv 'GH_ORG'        $Org          $ConfigEnv
    Write-ConfigKv 'RUNNER_LABELS' $Labels       $ConfigEnv
    Write-ConfigKv 'RUNNER_NAME'   $RunnerName   $ConfigEnv
    Write-ConfigKv 'RUNNER_TOKEN'  $Token        $ConfigEnv
    Write-ConfigKv 'BROKER_URL'    $BrokerUrl    $ConfigEnv
    Write-ConfigKv 'BROKER_SECRET' $BrokerSecret $ConfigEnv
    Write-ConfigKv 'ACCESS_TOKEN'  $AccessToken  $ConfigEnv

    # Copy runner-loop.ps1 into the instance dir so it runs relative to its own runner binaries.
    Copy-Item -Path $LoopScript -Destination (Join-Path $InstDir 'runner-loop.ps1') -Force

    # When running as a non-admin user, that account must be able to WRITE the runner's working state
    # (_work, _diag, .runner, .credentials) under the instance dir. Grant it Modify (config.env stays
    # Read-only to it via the ACL above).
    if ($RunAsUser -ne '') {
        $dirAcl  = Get-Acl $InstDir
        $dirRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $RunAsUser,
            [Security.AccessControl.FileSystemRights]::Modify,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $dirAcl.AddAccessRule($dirRule)
        Set-Acl -Path $InstDir -AclObject $dirAcl
        # Re-assert config.env's tighter ACL (the dir grant must not widen the credential file).
        Set-CredentialAcl -FilePath $ConfigEnv -ReadUser $RunAsUser
    }

    # ── Register a scheduled task for this instance ────────────────────────────
    # WHY Task Scheduler over NSSM or SC: it's built in (zero deps), supports 'run whether logged on
    # or not' with stored credentials, automatic restart on failure, and no third-party binaries.
    $TaskName    = "gh-runner-windows@$i"
    $TaskAction  = New-ScheduledTaskAction `
        -Execute   'powershell.exe' `
        -Argument  "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstDir 'runner-loop.ps1')`"" `
        -WorkingDirectory $InstDir

    # AtStartup trigger — the task starts automatically on system boot.
    $TaskTrigger = New-ScheduledTaskTrigger -AtStartup

    # Task identity: a non-admin -RunAsUser (Password logon, confines jobs) if given, else SYSTEM
    # (zero setup, but jobs run as SYSTEM). Both get RunLevel Highest so the runner can self-manage.
    if ($RunAsUser -ne '') {
        $TaskPrincipal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Password -RunLevel Highest
    } else {
        $TaskPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }

    # Restart on failure: up to 3 times at 1-minute intervals. ExecutionTimeLimit 0 = no limit (the
    # supervisor loop runs indefinitely; a finite cap would kill a long-but-legitimate run).
    $TaskSettings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit           ([TimeSpan]::Zero) `
        -RestartCount                  3 `
        -RestartInterval              (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries

    # Register (or replace) the task. For a Password-logon user the credential is supplied here.
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Info "Replacing existing scheduled task: $TaskName"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $registerArgs = @{
        TaskName    = $TaskName
        Action      = $TaskAction
        Trigger     = $TaskTrigger
        Principal   = $TaskPrincipal
        Settings    = $TaskSettings
        Description = "Ephemeral GitHub Actions runner instance $i (gh-runner-windows@$i). Managed by install.ps1."
    }
    if ($RunAsUser -ne '') {
        $registerArgs['User']     = $RunAsUser
        $registerArgs['Password'] = $RunAsPassword
    }
    Register-ScheduledTask @registerArgs | Out-Null

    # Start the task immediately (don't wait for next reboot).
    Start-ScheduledTask -TaskName $TaskName
    Write-Info "Scheduled task $TaskName registered and started."
}

Remove-Item -Path $TmpZip -Force -ErrorAction SilentlyContinue

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '==========================================================='
Write-Host " windows runners installed: $Count instance(s) under $RunnerBase"
Write-Host " Owner: $Owner    Org: $Org    Labels: $Labels"
$runAs = if ($RunAsUser -ne '') { $RunAsUser } else { 'NT AUTHORITY\SYSTEM (jobs run as SYSTEM — see -RunAsUser to confine)' }
Write-Host " Run as : $runAs"
Write-Host '==========================================================='
Write-Host ' Status  : Get-ScheduledTask -TaskName "gh-runner-windows@*"'
Write-Host ' Logs    : Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational | Where-Object { $_.Message -like "*gh-runner-windows*" } | Select-Object -First 20'
Write-Host '           Or check runner _diag\ logs inside each instance dir.'
Write-Host " Stop    : Stop-ScheduledTask  -TaskName 'gh-runner-windows@1'  (per instance)"
Write-Host " Start   : Start-ScheduledTask -TaskName 'gh-runner-windows@1'"
Write-Host " Uninstall: .\uninstall.ps1 -Count $Count -RunnerBase `"$RunnerBase`""
Write-Host '==========================================================='
