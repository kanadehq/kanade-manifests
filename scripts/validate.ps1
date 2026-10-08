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

# ---- result -----------------------------------------------------------------
if ($script:problems.Count -gt 0) {
  Write-Host "`n$($script:problems.Count) problem(s) found." -ForegroundColor Red
  exit 1
}
Write-Host "OK: $($jobs.Count) jobs, $($schedules.Count) schedules, $($views.Count) views, $($groups.Count) groups."
