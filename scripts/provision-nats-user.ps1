<#
.SYNOPSIS
  Distribute the agent role's NATS user to the fleet - Windows and
  Linux/macOS - from one set of values: the provisioning jobs and schedules,
  the readiness checks and schedules, and the OS and readiness groups.

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

  One invocation fills and applies both the Windows manifests
  (provision-nats-user, check-nats-user) and the Unix ones
  (provision-nats-user-unix, check-nats-user-unix) from the same values, so the
  platforms cannot end up on different credentials. pwsh runs this script on
  any operating system.

  Does NOT touch the broker. Switching it is a separate step, done only after
  every machine, of every platform, reports ready (the not-ready query in
  configs/groups/nats-user-ready-fleet.yaml is empty).

.PARAMETER User
  The agent role's NATS user. Prompted for if omitted. Letters, digits, '_',
  '.' and '-', at most 128 characters.

.PARAMETER Password
  The password as a SecureString. Prefer the environment variable or the
  prompt over building a SecureString from plain text on a command line.

.PARAMETER JobVersion
  Version stamped on BOTH provisioning jobs (Windows and Unix). MUST be higher
  than the larger of the two versions committed in the manifests, and higher than the last version applied from this
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
$provisionSrcs = @(
    (Join-Path $repoRoot 'configs/jobs/provision-nats-user.yaml'),
    (Join-Path $repoRoot 'configs/jobs/provision-nats-user-unix.yaml')
)

if (-not (Get-Command kanade -ErrorAction SilentlyContinue)) {
    throw "kanade CLI not found on PATH - install it before running this script."
}

# ---- the version must move -------------------------------------------------
# once_per_version remembers, per machine, the version it already applied. The
# same version with a new credential reaches nobody who ran the old one, and
# check-nats-user (presence only) keeps reporting them ready.
if ($JobVersion -notmatch '^\d+\.\d+\.\d+$') { throw "-JobVersion '$JobVersion' is not a x.y.z version." }
# Both provisioning jobs are stamped with the same version, so the guard is on
# the larger of the two committed ones.
$committedVersions = @()
foreach ($src in $provisionSrcs) {
    if (-not (Test-Path $src)) { throw "missing manifest: $src" }
    $v = [regex]::Match((Get-Content -LiteralPath $src -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
    if ($v -notmatch '^\d+\.\d+\.\d+$') { throw "cannot read an x.y.z version from $src" }
    $committedVersions += [version]$v
}
$committed = ($committedVersions | Sort-Object -Descending | Select-Object -First 1).ToString()
if ($JobVersion -eq $committed) {
    throw "-JobVersion $JobVersion is the version already in a manifest. Bump it: the schedule reaches nobody who applied that version."
}
if ([version]$JobVersion -lt [version]$committed) { throw "-JobVersion $JobVersion is older than the manifests' $committed." }
# The manifest never records what was last APPLIED, so remember it locally: a
# second credential change under the same version would otherwise pass the
# check above and reach nobody who already ran the first. This only sees
# applies made from this machine and account; from elsewhere, check the
# registered job's version yourself.
$stateFile = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'kanade') 'nats-user-last-version.txt'
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

# Same rules both agent-side jobs enforce; failing here is cheaper than failing
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
# basename and would otherwise overwrite each other. Jobs first, the groups
# next (a schedule naming a missing group, like one naming a missing job, is an
# error mid-apply), schedules last. Provision = the job carrying the credential,
# whose version is stamped from -JobVersion.
$cfg = Join-Path $repoRoot 'configs'
$targets = @(
    @{ Name = 'provision-nats-user job';        Kind = 'job';      Provision = $true;  Out = 'job-provision-nats-user.yaml';           Src = (Join-Path $cfg 'jobs/provision-nats-user.yaml') }
    @{ Name = 'check-nats-user job';            Kind = 'job';      Provision = $false; Out = 'job-check-nats-user.yaml';               Src = (Join-Path $cfg 'jobs/check-nats-user.yaml') }
    @{ Name = 'provision-nats-user-unix job';   Kind = 'job';      Provision = $true;  Out = 'job-provision-nats-user-unix.yaml';      Src = (Join-Path $cfg 'jobs/provision-nats-user-unix.yaml') }
    @{ Name = 'check-nats-user-unix job';       Kind = 'job';      Provision = $false; Out = 'job-check-nats-user-unix.yaml';          Src = (Join-Path $cfg 'jobs/check-nats-user-unix.yaml') }
    @{ Name = 'windows-agents group';           Kind = 'group';    Provision = $false; Out = 'group-windows-agents.yaml';              Src = (Join-Path $cfg 'groups/windows-agents.yaml') }
    @{ Name = 'unix-agents group';              Kind = 'group';    Provision = $false; Out = 'group-unix-agents.yaml';                 Src = (Join-Path $cfg 'groups/unix-agents.yaml') }
    @{ Name = 'nats-user-ready group';          Kind = 'group';    Provision = $false; Out = 'group-nats-user-ready.yaml';             Src = (Join-Path $cfg 'groups/nats-user-ready.yaml') }
    @{ Name = 'nats-user-ready-unix group';     Kind = 'group';    Provision = $false; Out = 'group-nats-user-ready-unix.yaml';        Src = (Join-Path $cfg 'groups/nats-user-ready-unix.yaml') }
    @{ Name = 'nats-user-ready-fleet group';    Kind = 'group';    Provision = $false; Out = 'group-nats-user-ready-fleet.yaml';       Src = (Join-Path $cfg 'groups/nats-user-ready-fleet.yaml') }
    @{ Name = 'provision schedule';             Kind = 'schedule'; Provision = $false; Out = 'schedule-provision-nats-user.yaml';      Src = (Join-Path $cfg 'schedules/provision-nats-user.yaml') }
    @{ Name = 'check schedule';                 Kind = 'schedule'; Provision = $false; Out = 'schedule-check-nats-user.yaml';          Src = (Join-Path $cfg 'schedules/check-nats-user.yaml') }
    @{ Name = 'provision schedule (unix)';      Kind = 'schedule'; Provision = $false; Out = 'schedule-provision-nats-user-unix.yaml'; Src = (Join-Path $cfg 'schedules/provision-nats-user-unix.yaml') }
    @{ Name = 'check schedule (unix)';          Kind = 'schedule'; Provision = $false; Out = 'schedule-check-nats-user-unix.yaml';     Src = (Join-Path $cfg 'schedules/check-nats-user-unix.yaml') }
)

# A directory only the operator (and SYSTEM, on Windows) can read, from the
# moment it exists: the copies hold the password.
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kanade-nats-{0}" -f ([Guid]::NewGuid().ToString('N')))
if ($onWindows) {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $sys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($sid in @($me, $sys)) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
}

try {
    if (-not $onWindows) {
        # Created 0700 in one step, so there is no window with a wider mode.
        & mkdir -m 700 $tmpDir
        if ($LASTEXITCODE -ne 0) { throw "cannot create the private temporary directory" }
    } elseif ([System.IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [System.Security.AccessControl.DirectorySecurity]))) {
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
        if ($t.Provision) {
            # Only the distribution jobs' version re-arms the fleet, and both
            # platforms are stamped alike.
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
        Write-Host "  1. Wait for check-nats-user (Windows) and check-nats-user-unix (Linux/macOS) to report ok; offline machines catch up as they return"
        Write-Host "  2. macOS: a Mac whose launcher predates the user pair reports 'launcher does not pass the user pair' - re-run the agent's setup-agent.sh there once"
        Write-Host "  3. List the machines that are NOT ready (query in configs/groups/nats-user-ready-fleet.yaml) until it is empty"
        Write-Host "  4. Unix agents restart themselves about 30 seconds after a write; confirm they came back before the switch"
        Write-Host "  5. Only then switch the broker (done elsewhere), keeping the switch revertible"
    }
} finally {
    # The copies hold the password: remove them on every path, dry run included.
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmpDir
}
