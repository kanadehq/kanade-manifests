<#
.SYNOPSIS
  Distribute the agent role's NATS user to the fleet: provisioning job and
  schedule, readiness check and schedule, and the readiness group - from one
  set of values.

.DESCRIPTION
  The manifests under configs/ ship with REPLACE- placeholders. This script
  fills them into temporary copies (the same shape as rotate-command-keys.ps1),
  so no secret is ever committed. The user and password are written into the
  copies base64-encoded: that keeps odd characters from breaking the YAML or
  the PowerShell, and an unfilled placeholder is not valid base64, so the
  agent-side script refuses to write it. Base64 is not protection - the
  rendered copies hold the password and are deleted when the script ends,
  whether it applied, ran dry, or failed.

  The password is never taken as a plain command-line argument by default. It
  is read from, in order: -Password (a SecureString), the environment variable
  KANADE_NATS_AGENT_PASSWORD, or a hidden prompt asked twice (a typo passes the
  fleet check and locks the machine out at the broker switch, so it is
  confirmed). Nothing here echoes it.

  Does NOT touch the broker. Switching it is a separate step, done only after
  check-nats-user reports every Windows machine ready.

.PARAMETER User
  The agent role's NATS user. Prompted for if omitted. Letters, digits, '_',
  '.' and '-', at most 128 characters.

.PARAMETER Password
  The password as a SecureString. Prefer the environment variable or the
  prompt over building a SecureString from plain text on a command line.

.PARAMETER JobVersion
  Version stamped on the provisioning job. MUST differ from the version
  committed in the manifest and higher than the last version applied from this
  machine (recorded when an apply starts), and must be bumped whenever the credential
  changes: the schedule uses `per_pc: once_per_version`, so the version is what
  re-arms the fleet. Reusing it means the new value reaches nobody who already
  applied the old one, silently.

.PARAMETER ConfirmVersionBumped
  Required with -Apply on a machine with no record of earlier applies: states
  that you checked the registered job's version and -JobVersion is higher.

.PARAMETER Apply
  Actually run the `kanade` commands. Without it the script prints what it
  would do and applies nothing - the default, because this writes a credential
  to every machine.

.EXAMPLE
  # Dry run (default); the password is asked for without echo:
  PS> .\scripts\provision-nats-user.ps1 -User agent -JobVersion 0.2.0

.EXAMPLE
  # Apply, password from the environment:
  PS> $env:KANADE_NATS_AGENT_PASSWORD = Read-Host
  PS> .\scripts\provision-nats-user.ps1 -User agent -JobVersion 0.2.0 -Apply
#>
[CmdletBinding()]
param(
    [string]$User = '',
    [System.Security.SecureString]$Password,
    [Parameter(Mandatory)][string]$JobVersion,
    [string]$Server = '',
    [string]$BackendUrl = '',
    [switch]$ConfirmVersionBumped,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$jobSrc = Join-Path $repoRoot 'configs\jobs\provision-nats-user.yaml'

if (-not (Get-Command kanade -ErrorAction SilentlyContinue)) {
    throw "kanade CLI not found on PATH - install it before running this script."
}

# ---- the version must move -------------------------------------------------
# once_per_version remembers, per machine, the version it already applied. The
# same version with a new credential reaches nobody who ran the old one, and
# check-nats-user (presence only) keeps reporting them ready.
if ($JobVersion -notmatch '^\d+\.\d+\.\d+$') { throw "-JobVersion '$JobVersion' is not a x.y.z version." }
if (-not (Test-Path $jobSrc)) { throw "missing manifest: $jobSrc" }
$committed = [regex]::Match((Get-Content -LiteralPath $jobSrc -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
if ($JobVersion -eq $committed) {
    throw "-JobVersion $JobVersion is the version already in the manifest. Bump it: the schedule reaches nobody who applied that version."
}
if ([version]$JobVersion -lt [version]$committed) { throw "-JobVersion $JobVersion is older than the manifest's $committed." }
# The manifest never records what was last APPLIED, so remember it locally: a
# second credential change under the same version would otherwise pass the
# check above and reach nobody who already ran the first. This only sees
# applies made from this machine and account; from elsewhere, check the
# registered job's version yourself.
$stateFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'kanade\nats-user-last-version.txt'
if (-not (Test-Path $stateFile) -and $Apply -and -not $ConfirmVersionBumped) {
    throw "no record of earlier applies from this machine. Check the version the registered provision-nats-user job carries, make sure -JobVersion is higher, and re-run with -ConfirmVersionBumped."
}
if (Test-Path $stateFile) {
    $last = (Get-Content -LiteralPath $stateFile -Raw).Trim()
    if ($last -match '^\d+\.\d+\.\d+$' -and [version]$JobVersion -le [version]$last) {
        throw "-JobVersion $JobVersion was already applied from this machine (last: $last). Use a higher version: the schedule reaches nobody who applied it."
    }
}

# ---- collect the credential without echoing it -----------------------------
function ConvertTo-PlainText {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not $User) { $User = Read-Host 'NATS user for the agent role' }

$plain = $null
if ($Password) {
    $plain = ConvertTo-PlainText $Password
} elseif ($env:KANADE_NATS_AGENT_PASSWORD) {
    $plain = $env:KANADE_NATS_AGENT_PASSWORD
} else {
    $p1 = ConvertTo-PlainText (Read-Host 'NATS password for the agent role' -AsSecureString)
    $p2 = ConvertTo-PlainText (Read-Host 'Repeat the password' -AsSecureString)
    if ($p1 -cne $p2) { throw 'the two passwords differ.' }
    $plain = $p1
}

# Same rules the agent-side job enforces; failing here is cheaper than failing
# on every machine.
if ($User -notmatch '^[A-Za-z0-9_.-]{1,128}$') { throw "user must be 1-128 characters of A-Z a-z 0-9 _ . -" }
if ([string]::IsNullOrWhiteSpace($plain))      { throw 'the password is empty.' }
if ($plain.Length -gt 1024)                    { throw 'the password is implausibly long.' }
if ($plain -match '[\p{Cc}]')                  { throw 'the password contains a control character.' }

$enc = New-Object System.Text.UTF8Encoding($false)
$userB64 = [Convert]::ToBase64String($enc.GetBytes($User))
$passB64 = [Convert]::ToBase64String($enc.GetBytes($plain))
$plain = $null

# ---- render ----------------------------------------------------------------
# APPLY order, with the kind in the output name: a job and its schedule share a
# basename and would otherwise overwrite each other. Jobs first, the group next,
# schedules last (a schedule naming a missing job is an error mid-apply).
$targets = @(
    @{ Name = 'provision-nats-user job';      Kind = 'job';      Out = 'job-provision-nats-user.yaml';      Src = "$repoRoot\configs\jobs\provision-nats-user.yaml" }
    @{ Name = 'check-nats-user job';          Kind = 'job';      Out = 'job-check-nats-user.yaml';          Src = "$repoRoot\configs\jobs\check-nats-user.yaml" }
    @{ Name = 'nats-user-ready group';        Kind = 'group';    Out = 'group-nats-user-ready.yaml';        Src = "$repoRoot\configs\groups\nats-user-ready.yaml" }
    @{ Name = 'provision schedule';           Kind = 'schedule'; Out = 'schedule-provision-nats-user.yaml'; Src = "$repoRoot\configs\schedules\provision-nats-user.yaml" }
    @{ Name = 'check schedule';               Kind = 'schedule'; Out = 'schedule-check-nats-user.yaml';     Src = "$repoRoot\configs\schedules\check-nats-user.yaml" }
)

# A directory only the operator and SYSTEM can read, from the moment it exists:
# the copies hold the password.
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kanade-nats-{0}" -f ([Guid]::NewGuid().ToString('N')))
$sec = New-Object System.Security.AccessControl.DirectorySecurity
$sec.SetAccessRuleProtection($true, $false)
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$sys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
foreach ($sid in @($me, $sys)) {
    $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}

try {
    if ([System.IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))) {
        [System.IO.Directory]::CreateDirectory($tmpDir, $sec) | Out-Null
    } else {
        [System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.DirectoryInfo($tmpDir)), $sec) | Out-Null
    }
    Write-Host "Rendering into a private temporary directory (deleted when this script ends)"
    Write-Host ''

    $rendered = @()
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Src)) { throw "missing manifest: $($t.Src)" }
        $text = (Get-Content -LiteralPath $t.Src -Raw).
            Replace('REPLACE-nats-user-b64',     $userB64).
            Replace('REPLACE-nats-password-b64', $passB64)
        if ($t.Kind -eq 'job' -and $t.Src -like '*provision-nats-user.yaml') {
            # Only the distribution job's version re-arms the fleet.
            $text = $text -replace '(?m)^version:.*$', "version: $JobVersion"
        }
        if ($text -match 'REPLACE-') {
            throw "unsubstituted placeholder left in $($t.Src) - the script and the manifest have drifted apart."
        }
        $dst = Join-Path $tmpDir $t.Out
        if (Test-Path $dst) { throw "two manifests would render to $($t.Out) - the Out names must be unique" }
        Set-Content -LiteralPath $dst -Value $text -Encoding utf8
        $rendered += @{ Name = $t.Name; Path = $dst; Kind = $t.Kind }
        Write-Host ("  {0,-28} -> {1}" -f $t.Name, $t.Out)
    }

    Write-Host ''
    Write-Host "user:        $User (password not shown)"
    Write-Host "job version: $JobVersion  <- bump this on EVERY credential change, or the schedule reaches nobody"
    Write-Host ''

    # ---- apply -------------------------------------------------------------
    $globals = @()
    if ($Server)     { $globals += @('--server', $Server) }
    if ($BackendUrl) { $globals += @('--backend-url', $BackendUrl) }

    function Invoke-Kanade {
        param([string[]]$KanadeArgs)
        $line = 'kanade ' + (($globals + $KanadeArgs) -join ' ')
        if (-not $Apply) { Write-Host "  [dry-run] $line"; return }
        Write-Host "  $line"
        & kanade @($globals + $KanadeArgs)
        if ($LASTEXITCODE -ne 0) { throw "command failed (exit $LASTEXITCODE): $line" }
    }

    Write-Host '--- apply ---'
    if ($Apply) {
        # Burn the version BEFORE the first create: once the job is registered
        # under it and the schedule is enabled, machines may run it, and a
        # failure part-way must not let the same version be reused.
        New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
        Set-Content -LiteralPath $stateFile -Value $JobVersion
    }
    foreach ($r in $rendered) {
        switch ($r.Kind) {
            'job'      { Invoke-Kanade @('job', 'create', $r.Path) }
            'group'    { Invoke-Kanade @('group', 'def', 'create', $r.Path) }
            'schedule' { Invoke-Kanade @('schedule', 'create', $r.Path) }
            default    { throw "unknown manifest kind '$($r.Kind)' for $($r.Name)" }
        }
    }

    Write-Host ''
    if (-not $Apply) {
        Write-Host "Dry run. Re-run with -Apply to distribute the credential." -ForegroundColor Yellow
    } else {
        Write-Host "Applied. Distribution starts on the schedule's next tick." -ForegroundColor Green
        Write-Host ''
        Write-Host "Next, in order:"
        Write-Host "  1. Wait for check-nats-user to report ok everywhere; offline machines catch up as they return"
        Write-Host "  2. List the machines that are NOT ready (query in configs/groups/nats-user-ready.yaml) until it is empty"
        Write-Host "  3. Only then switch the broker (done elsewhere), keeping the switch revertible"
    }
} finally {
    # The copies hold the password: remove them on every path, dry run included.
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmpDir
}
