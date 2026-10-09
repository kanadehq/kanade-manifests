<#
.SYNOPSIS
  Validate every manifest and script in this repository (CI and local).

.DESCRIPTION
  Runs, in order, and reports every problem before exiting non-zero:
    1. `kanade {job,schedule,view,group def} validate` over configs/.
       Files are enumerated here instead of passing directories, because the
       CLI skips nested directories and would read `*.schedule.yaml` as a job.
    2. Cross-checks: schedule job_id -> an existing job id, README links
       resolve, every manifest under configs/ is linked from README.
    3. PowerShell syntax of scripts/**/*.ps1 and of job `execute.script`
       bodies (parsed only, never run), and `sh -n` of `shell: sh` job
       bodies. `REPLACE-` placeholders are expected and are not an error.
    4. NATS credential manifests: each provision job carries exactly the two
       placeholder lines and no other base64 value (so no secret is committed),
       and no NATS schedule targets `all: true` (a target has no OS filter, so
       the Windows and Unix schedules are kept apart by groups, which must exist).

  Needs `kanade` and `pwsh` on PATH. Run from anywhere:  pwsh scripts/validate.ps1
#>
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

# Schedules whose job_id is registered outside this repository. Each entry is
# 'schedule path|job_id' and needs a comment saying where the job lives.
$ExternalJobs = @(
)

$script:problems = [System.Collections.Generic.List[string]]::new()
function Add-Problem([string]$Message) {
  $script:problems.Add($Message)
  Write-Host "::error::$Message"
}
function Get-Yaml([string]$Dir, [switch]$Recurse) {
  Get-ChildItem -Path $Dir -Recurse:$Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.yaml', '.yml' } |
    ForEach-Object { (Resolve-Path -Relative $_.FullName).TrimStart('.', '/', '\') -replace '\\', '/' } |
    Sort-Object
}

# ---- classify configs/ ------------------------------------------------------
$allYaml   = @(Get-Yaml 'configs' -Recurse)
$jobs      = @($allYaml | Where-Object { $_ -like 'configs/jobs/*' -and $_ -notlike '*.schedule.y*ml' })
$schedules = @($allYaml | Where-Object { $_ -like 'configs/schedules/*' -or ($_ -like 'configs/jobs/*' -and $_ -like '*.schedule.y*ml') })
$views     = @($allYaml | Where-Object { $_ -like 'configs/views/*' })
$groups    = @($allYaml | Where-Object { $_ -like 'configs/groups/*' })
foreach ($c in @{ jobs = $jobs; schedules = $schedules; views = $views; groups = $groups }.GetEnumerator()) {
  if ($c.Value.Count -eq 0) { Add-Problem "no $($c.Key) manifests found under configs/" }
}
foreach ($f in $allYaml | Where-Object { $_ -notin ($jobs + $schedules + $views + $groups) }) {
  Add-Problem "${f}: not under configs/{jobs,schedules,views,groups}, so no validator covers it"
}

# ---- 1. kanade validate -----------------------------------------------------
if (-not (Get-Command kanade -ErrorAction SilentlyContinue)) {
  Add-Problem 'kanade CLI not found on PATH'
} else {
  Write-Host "kanade: $(kanade --version)"
  $runs = @(
    @{ name = 'job';       args = @('job', 'validate');          files = $jobs },
    @{ name = 'schedule';  args = @('schedule', 'validate');     files = $schedules },
    @{ name = 'view';      args = @('view', 'validate');         files = $views },
    @{ name = 'group def'; args = @('group', 'def', 'validate'); files = $groups }
  )
  foreach ($r in $runs) {
    if ($r.files.Count -eq 0) { continue }
    Write-Host "::group::kanade $($r.name) validate ($($r.files.Count) files)"
    & kanade @($r.args) @($r.files)
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'
    # The CLI names each failing file in its own output above.
    if ($code -ne 0) { Add-Problem "kanade $($r.name) validate failed (exit $code); see the file names above" }
  }
}

# ---- minimal manifest reader ------------------------------------------------
# Reads only top-level `id:` / `job_id:` and the execute block's `shell:` and
# `script: |` body. Anything else fails loudly instead of being skipped.
function Get-Scalar([string[]]$Lines, [string]$Key) {
  foreach ($l in $Lines) {
    if ($l -match "^$Key\s*:\s*(.*?)\s*(#.*)?$") { return $Matches[1].Trim('"', "'") }
  }
}
function Get-ExecuteInfo([string]$Path) {
  $lines = [System.IO.File]::ReadAllLines((Join-Path (Get-Location) $Path))
  $info = @{ Id = Get-Scalar $lines 'id'; Shell = $null; Body = $null; BodyLine = 0; Error = $null }
  $start = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^execute\s*:' })
  if ($start -lt 0) { $info.Error = 'no top-level execute: block'; return $info }
  $i = $start + 1
  while ($i -lt $lines.Count -and ($lines[$i] -match '^\s' -or $lines[$i] -match '^\s*(#.*)?$')) {
    if ($lines[$i] -match '^  shell\s*:\s*(.*?)\s*(#.*)?$') { $info.Shell = $Matches[1].Trim('"', "'") }
    if ($lines[$i] -match '^  script\s*:\s*(.*?)\s*$') {
      if ($Matches[1] -notmatch '^\|[-+]?$') { $info.Error = "execute.script is not a '|' block ($($Matches[1]))"; return $info }
      $body = [System.Collections.Generic.List[string]]::new()
      $info.BodyLine = $i + 2
      $j = $i + 1
      while ($j -lt $lines.Count -and ($lines[$j] -match '^\s*$' -or $lines[$j] -match '^\s{3,}')) {
        $body.Add($lines[$j]); $j++
      }
      $indent = ($body | Where-Object { $_.Trim() } | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
      $info.Body = ($body | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { '' } }) -join "`n"
      $i = $j
      continue  # keep scanning: shell: may come after script:
    }
    $i++
  }
  if ($null -ne $info.Body) { return $info }
  $info.Error = 'execute: has no script: (script_file: and other forms are not supported by this check)'
  $info
}

# ---- 2a. schedule job_id -> job id ------------------------------------------
$jobInfo = @{}
foreach ($j in $jobs) {
  $jobInfo[$j] = Get-ExecuteInfo $j
  if (-not $jobInfo[$j].Id) { Add-Problem "${j}: no top-level id:" }
  if ($jobInfo[$j].Error)   { Add-Problem "${j}: $($jobInfo[$j].Error)" }
}
$jobIds = @($jobInfo.Values | ForEach-Object { $_.Id } | Where-Object { $_ })
foreach ($s in $schedules) {
  $jid = Get-Scalar ([System.IO.File]::ReadAllLines((Join-Path (Get-Location) $s))) 'job_id'
  if (-not $jid) { Add-Problem "${s}: no top-level job_id:"; continue }
  if ($jid -notin $jobIds -and "$s|$jid" -notin $ExternalJobs) {
    Add-Problem "${s}: job_id '$jid' matches no job id in configs/jobs (add it to `$ExternalJobs if it lives elsewhere)"
  }
}

# ---- 2b. README links and coverage ------------------------------------------
$readme = Get-Content -Raw README.md
$linked = [System.Collections.Generic.HashSet[string]]::new()
foreach ($m in [regex]::Matches($readme, '\]\(([^)\s]+)\)')) {
  $t = $m.Groups[1].Value
  if ($t -match '^([a-z][a-z0-9+.-]*:|#)') { continue }
  $t = ($t -replace '[#?].*$', '')
  if (-not $t) { continue }
  if (-not (Test-Path -LiteralPath $t)) { Add-Problem "README.md: linked path '$t' does not exist"; continue }
  [void]$linked.Add($t.TrimStart('.', '/'))
}
foreach ($f in $allYaml | Where-Object { -not $linked.Contains($_) }) {
  Add-Problem "${f}: not linked from the README category tables"
}

# ---- 3. PowerShell syntax ---------------------------------------------------
function Test-Syntax([string]$Label, [int]$LineOffset, [scriptblock]$Parse) {
  $errs = $null
  & $Parse ([ref]$errs)
  foreach ($e in $errs) {
    Add-Problem "${Label}:$($e.Extent.StartLineNumber + $LineOffset):$($e.Extent.StartColumnNumber): $($e.Message)"
  }
}
foreach ($p in Get-ChildItem scripts -Recurse -Filter *.ps1 -File | ForEach-Object { $_.FullName }) {
  $rel = (Resolve-Path -Relative $p) -replace '\\', '/' -replace '^\./', ''
  Test-Syntax $rel 0 { param($e) [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, $e) }
}
foreach ($j in $jobs) {
  $info = $jobInfo[$j]
  if ($null -eq $info.Body -or $info.Shell -notin 'powershell', 'pwsh') { continue }
  Test-Syntax $j ($info.BodyLine - 1) { param($e) [void][System.Management.Automation.Language.Parser]::ParseInput($info.Body, [ref]$null, $e) }
}

foreach ($j in $jobs) {
  $info = $jobInfo[$j]
  if ($null -eq $info.Body -or $info.Shell -ne 'sh') { continue }
  $sh = Get-Command sh -ErrorAction SilentlyContinue
  if (-not $sh) { Write-Host "::warning::sh not found on PATH; skipping the syntax check of $j"; continue }
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, $info.Body + "`n")
    $out = & $sh.Source -n $tmp 2>&1
    if ($LASTEXITCODE -ne 0) { Add-Problem "${j}: sh -n failed: $(($out | Out-String).Trim() -replace [regex]::Escape($tmp), 'script')" }
  } finally { Remove-Item -Force -ErrorAction SilentlyContinue $tmp }
}

# ---- 4. NATS credential manifests --------------------------------------------
# Committed copies must hold placeholders only. Each provision job has exactly
# the two placeholder assignments and no other base64 assignment; rendering
# happens in scripts/provision-nats-user.ps1 into temporary copies.
$provisionJobs = @{
  'configs/jobs/provision-nats-user.yaml'      = @("`$userB64 = 'REPLACE-nats-user-b64'", "`$passB64 = 'REPLACE-nats-password-b64'")
  'configs/jobs/provision-nats-user-unix.yaml' = @("user_b64='REPLACE-nats-user-b64'", "pass_b64='REPLACE-nats-password-b64'")
}
foreach ($p in $provisionJobs.Keys) {
  if (-not (Test-Path -LiteralPath $p)) { Add-Problem "${p}: missing"; continue }
  $lines = [System.IO.File]::ReadAllLines((Join-Path (Get-Location) $p))
  foreach ($want in $provisionJobs[$p]) {
    $n = @($lines | Where-Object { $_.Trim() -ceq $want }).Count
    if ($n -ne 1) { Add-Problem "${p}: expected exactly one placeholder line '$want', found $n" }
  }
  $assigns = @($lines | Where-Object { $_ -match '(?i)b64\s*=\s*[''"]' })
  if ($assigns.Count -ne 2) { Add-Problem "${p}: $($assigns.Count) base64 assignment lines; only the 2 placeholder lines are allowed (is a credential committed?)" }
}
foreach ($f in @('configs/jobs/provision-nats-user-unix.yaml', 'configs/jobs/check-nats-user-unix.yaml',
                 'configs/schedules/provision-nats-user-unix.yaml', 'configs/schedules/check-nats-user-unix.yaml',
                 'configs/groups/unix-agents.yaml', 'configs/groups/windows-agents.yaml',
                 'configs/groups/nats-user-ready-unix.yaml', 'configs/groups/nats-user-ready-fleet.yaml')) {
  if ($f -notin $allYaml) { Add-Problem "${f}: missing" }
}
$groupIds = @($groups | ForEach-Object { Get-Scalar ([System.IO.File]::ReadAllLines((Join-Path (Get-Location) $_))) 'id' })
$natsSchedules = @{
  'configs/schedules/provision-nats-user.yaml'      = 'windows-agents'
  'configs/schedules/check-nats-user.yaml'          = 'windows-agents'
  'configs/schedules/provision-nats-user-unix.yaml' = 'unix-agents'
  'configs/schedules/check-nats-user-unix.yaml'     = 'unix-agents'
}
foreach ($s in $natsSchedules.Keys) {
  if (-not (Test-Path -LiteralPath $s)) { continue }
  $text = [System.IO.File]::ReadAllText((Join-Path (Get-Location) $s))
  if ($text -match '(?m)^\s+all\s*:\s*true') { Add-Problem "${s}: targets all: true; a target has no OS filter, use the $($natsSchedules[$s]) group" }
  if ($text -notmatch "(?m)^\s+groups\s*:\s*\[\s*$($natsSchedules[$s])\s*\]") { Add-Problem "${s}: must target groups: [$($natsSchedules[$s])]" }
  if ($natsSchedules[$s] -notin $groupIds) { Add-Problem "${s}: group '$($natsSchedules[$s])' is not defined under configs/groups" }
}

# ---- 5. Unix provisioning job, run for real ----------------------------------
# The job body is run as written, in a scratch directory: only the fixed paths
# are pointed at it, and uname / chown / systemd-run / systemctl / launchctl /
# sleep are stubs that log their arguments. A stub log shows that a restart was
# requested, not that a service restarted.
$unixJob = 'configs/jobs/provision-nats-user-unix.yaml'
$shCmd = Get-Command sh -ErrorAction SilentlyContinue
if (-not $shCmd) {
  Write-Host "::warning::sh not found on PATH; skipping the run of $unixJob"
} elseif ($null -eq $jobInfo[$unixJob] -or $null -eq $jobInfo[$unixJob].Body) {
  Add-Problem "${unixJob}: no script body to run"
} else {
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("kanade-provision-test-" + [Guid]::NewGuid().ToString('N'))
  $oldPath = $env:PATH
  try {
    [void](New-Item -ItemType Directory -Path $scratch)
    $bin = Join-Path $scratch 'bin'; [void](New-Item -ItemType Directory -Path $bin)
    $etc = Join-Path $scratch 'etc'; $sd = Join-Path $scratch 'sd'; $plistT = Join-Path $scratch 'agent.plist'
    $log = Join-Path $scratch 'calls.log'
    $stubs = @{
      'uname'       = 'echo "$FAKE_OS"'
      'chown'       = 'exit 0'
      'sleep'       = 'exit 0'
      'systemd-run' = 'echo "systemd-run $*" >> "$STUB_LOG"'
      'systemctl'   = 'echo "systemctl $*" >> "$STUB_LOG"'
      'launchctl'   = 'echo "launchctl $*" >> "$STUB_LOG"'
    }
    foreach ($n in $stubs.Keys) {
      [System.IO.File]::WriteAllText((Join-Path $bin $n), "#!/bin/sh`n$($stubs[$n])`n", $utf8)
      & chmod +x (Join-Path $bin $n)
    }
    $body = $jobInfo[$unixJob].Body
    $subs = [ordered]@{
      'dir=/etc/kanade'                                    = "dir='$etc'"
      'plist=/Library/LaunchDaemons/com.kanade.agent.plist' = "plist='$plistT'"
      'sdroot=/run/systemd/system'                         = "sdroot='$sd'"
    }
    foreach ($k in $subs.Keys) {
      if (([regex]::Matches($body, [regex]::Escape($k))).Count -ne 1) {
        Add-Problem "${unixJob}: test isolation expects exactly one line '$k'"
      }
      $body = $body.Replace($k, $subs[$k])
    }
    $b64 = { param([string]$s) [Convert]::ToBase64String($utf8.GetBytes($s)) }
    $fixedErr = 'NATS password is empty'
    $env:PATH = $bin + [System.IO.Path]::PathSeparator + $oldPath
    $env:STUB_LOG = $log

    function Invoke-Unix([string]$Case, [string]$Os, [string]$Pass, $EnvText) {
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $etc, $sd, $log, $plistT
      [void](New-Item -ItemType Directory -Path $etc); [void](New-Item -ItemType Directory -Path $sd)
      Set-Content -NoNewline -Path $log -Value ''
      Set-Content -NoNewline -Path $plistT -Value 'KANADE_NATS_USER'
      $ef = Join-Path $etc 'agent.env'
      if ($null -ne $EnvText) { [System.IO.File]::WriteAllBytes($ef, $utf8.GetBytes($EnvText)) }
      $script = Join-Path $scratch 'job.sh'
      $text = $body.Replace("'REPLACE-nats-user-b64'", "'$(& $b64 'agent-user')'").Replace("'REPLACE-nats-password-b64'", "'$(& $b64 $Pass)'")
      [System.IO.File]::WriteAllText($script, $text + "`n", $utf8)
      $env:FAKE_OS = $Os
      $errf = Join-Path $scratch 'err.txt'
      $out = (& $shCmd.Source $script 2> $errf | Out-String).Trim()
      $code = $LASTEXITCODE
      $err = [System.IO.File]::ReadAllText($errf).Trim()
      $leak = ($out + $err).Contains($Pass) -or ($out + $err).Contains((& $b64 $Pass))
      if ($leak) { Add-Problem "${unixJob} [$Case]: output contains the test password" }
      [pscustomobject]@{
        Code = $code; Out = $out; Err = $err
        Calls = [System.IO.File]::ReadAllText($log)
        File = $(if (Test-Path -LiteralPath $ef) { , [System.IO.File]::ReadAllBytes($ef) } else { $null })
      }
    }
    function Assert-Case([string]$Case, [bool]$Ok) { if (-not $Ok) { Add-Problem "${unixJob} [$Case]: unexpected result" } }
    $pw = 'test-pass word'

    $r = Invoke-Unix 'linux, no token line' 'Linux' $pw "OTHER=1`n"
    Assert-Case 'linux, no token line' ($r.Code -eq 0 -and $r.Out -eq 'written (restart pending)' -and -not $r.Calls.Contains('restart'))
    foreach ($tl in 'KANADE_NATS_TOKEN=', 'KANADE_NATS_TOKEN=""') {
      $r = Invoke-Unix 'linux, empty token' 'Linux' $pw "$tl`n"
      Assert-Case 'linux, empty token' ($r.Code -eq 0 -and $r.Out -eq 'written (restart pending)' -and -not $r.Calls.Contains('restart'))
    }
    $r = Invoke-Unix 'linux, token line' 'Linux' $pw "KANADE_NATS_TOKEN=`"t`"`n"
    Assert-Case 'linux, token line' ($r.Code -eq 0 -and $r.Out -eq 'written (restart scheduled)' -and $r.Calls.Contains('restart kanade-agent.service'))
    $r = Invoke-Unix 'no env file' 'Linux' $pw $null
    Assert-Case 'no env file' ($r.Code -eq 0 -and $r.Out -eq 'written (restart pending)' -and -not $r.Calls.Contains('restart'))
    $r = Invoke-Unix 'macos, no token line' 'Darwin' $pw "OTHER=1`n"
    Assert-Case 'macos, no token line' ($r.Code -eq 0 -and $r.Out -eq 'written (restart pending)')
    $r = Invoke-Unix 'macos, token line' 'Darwin' $pw "KANADE_NATS_TOKEN=t`n"
    Assert-Case 'macos, token line' ($r.Code -eq 0 -and $r.Out -eq 'written (restart scheduled)')

    foreach ($os in 'Linux', 'Darwin') {
      $orig = 'KANADE_NATS_TOKEN="t"'
      $r = Invoke-Unix "$os, no trailing newline" $os $pw $orig
      $user = if ($os -eq 'Linux') { 'KANADE_NATS_USER="agent-user"' } else { 'KANADE_NATS_USER=agent-user' }
      $pass = if ($os -eq 'Linux') { 'KANADE_NATS_PASSWORD="test-pass word"' } else { 'KANADE_NATS_PASSWORD=test-pass word' }
      $want = $utf8.GetBytes("$user`n$pass`n$orig")
      $same = $null -ne $r.File -and [System.Linq.Enumerable]::SequenceEqual([byte[]]$r.File, [byte[]]$want)
      Assert-Case "$os, no trailing newline" ($r.Code -eq 0 -and $same)
    }
    # A second run over the file the first one wrote reports unchanged.
    $ef = Join-Path $etc 'agent.env'
    $again = (& $shCmd.Source (Join-Path $scratch 'job.sh') 2>$null | Out-String).Trim()
    Assert-Case 'rerun after unterminated line' ($again -eq 'unchanged')

    $blank = [ordered]@{
      'U+3000'          = [string][char]0x3000
      'U+00A0 U+2000'   = ([string][char]0xA0 + [char]0x2000)
      'U+2028'          = [string][char]0x2028
      'U+202F U+205F'   = ([string][char]0x202F + [char]0x205F)
      'U+1680'          = [string][char]0x1680
      'ASCII spaces'    = " `t "
    }
    foreach ($k in $blank.Keys) {
      $r = Invoke-Unix "blank password $k" 'Linux' $blank[$k] "KANADE_NATS_TOKEN=t`n"
      $untouched = $null -ne $r.File -and $utf8.GetString([byte[]]$r.File) -eq "KANADE_NATS_TOKEN=t`n"
      Assert-Case "blank password $k" ($r.Code -ne 0 -and $r.Err -eq $fixedErr -and $r.Out -eq '' -and $untouched)
      $r = Invoke-Unix "blank password $k, no file" 'Linux' $blank[$k] $null
      Assert-Case "blank password $k, no file" ($r.Code -ne 0 -and $r.Err -eq $fixedErr -and $null -eq $r.File)
    }
    $r = Invoke-Unix 'password with inner spaces' 'Linux' ([string][char]0x3000 + 'x' + [char]0x3000) $null
    Assert-Case 'password with inner spaces' ($r.Code -eq 0)
    $r = Invoke-Unix 'control character' 'Linux' "a$([char]7)b" $null
    Assert-Case 'control character' ($r.Code -ne 0 -and $r.Err -eq 'NATS password contains a control character' -and $null -eq $r.File)
    $r = Invoke-Unix 'C1 control character' 'Linux' "a$([char]0x85)b" $null
    Assert-Case 'C1 control character' ($r.Code -ne 0 -and $r.Err -eq 'NATS password contains a control character')
    $r = Invoke-Unix 'password 1024 units' 'Linux' ('a' * 1024) $null
    Assert-Case 'password 1024 units' ($r.Code -eq 0)
    $r = Invoke-Unix 'password 1025 units' 'Linux' ('a' * 1025) $null
    Assert-Case 'password 1025 units' ($r.Code -ne 0 -and $r.Err -eq 'NATS password is implausibly long' -and $null -eq $r.File)
  } finally {
    $env:PATH = $oldPath
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch
  }
}

# ---- result -----------------------------------------------------------------
if ($script:problems.Count -gt 0) {
  Write-Host "`n$($script:problems.Count) problem(s) found." -ForegroundColor Red
  exit 1
}
Write-Host "OK: $($jobs.Count) jobs, $($schedules.Count) schedules, $($views.Count) views, $($groups.Count) groups."
